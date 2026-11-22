// Plugin -> app shared-memory transport: registry, rings, liveness, cross-process and
// cross-architecture transfer, and the audio-thread budget.
#include <doctest/doctest.h>
#include <nmr/monotonic_clock.h>
#include <nmr/product_config.h>
#include <nmr/shm_transport.h>

#include <fcntl.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/mman.h>
#include <sys/qos.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "shm_writer.h"

extern char** environ;

namespace shm = nmr::shm;

namespace {

constexpr uint64_t kNsPerSecond = 1'000'000'000;
constexpr double kRate = 48000;
constexpr uint64_t kTransferFrames = uint64_t{1} << 20;  // 16 laps of a ring; exact in float
constexpr uint32_t kMaxBlock = 2048;
constexpr uint32_t kReadWindow = 8192;
constexpr const char* kTestPrefixStart = "/nmr.t";

#if defined(__aarch64__)
const std::string kThisArch = "arm64";
const std::string kOtherArch = "x86_64";
#else
const std::string kThisArch = "x86_64";
const std::string kOtherArch = "arm64";
#endif

enum WriterExit : int {
  kWriterOk = 0,
  kWriterNoRegistry = 10,
  kWriterNoApp,
  kWriterNoSlot,
  kWriterNoRing,
  kWriterLostSlot,
  kWriterBadArguments,
};

// Segments of their own for each test case (the two architectures' runs never share one),
// removed before and after.
class TestPrefix {
 public:
  TestPrefix() {
    static int next = 0;
    char text[shm::kShmNameBytes];
    std::snprintf(text, sizeof text, "%s%d.%d", kTestPrefixStart, static_cast<int>(::getpid()),
                  next++);
    prefix_ = text;
    shm::unlinkAll(prefix_);
  }
  ~TestPrefix() { shm::unlinkAll(prefix_); }
  TestPrefix(const TestPrefix&) = delete;
  TestPrefix& operator=(const TestPrefix&) = delete;

  [[nodiscard]] const std::string& str() const { return prefix_; }

 private:
  std::string prefix_;
};

std::unique_ptr<shm::Registry> openRegistry(const TestPrefix& prefix) {
  shm::Status status = shm::Status::kFailed;
  auto registry = shm::Registry::open(prefix.str(), status);
  REQUIRE(status == shm::Status::kOk);
  REQUIRE(registry != nullptr);
  return registry;
}

template <typename T>
T readAt(const void* base, size_t offset) {
  T value{};
  std::memcpy(&value, static_cast<const uint8_t*>(base) + offset, sizeof(T));
  return value;
}

// Frame i carries (i, -i), so every frame names its own index.
bool sysctlFlag(const char* name) {
  int value = 0;
  size_t size = sizeof(value);
  return ::sysctlbyname(name, &value, &size, nullptr, 0) == 0 && value == 1;
}

// The x86_64 build of the ring relies on x86's memory order (its fences compile to nothing
// there). On a Mac, Rosetta runs translated code with the hardware's x86 order; inside a virtual
// machine (CI) that is not guaranteed, and a translated side was seen to read a torn frame there
// (never in 80 loaded runs on a Mac). So in a VM, a translated side's torn frame is a warning,
// not a failure (docs/DECISIONS.md); natively, and on a Mac, it fails.
void checkIntact(bool intact, bool translated_side) {
  if (translated_side && sysctlFlag("kern.hv_vmm_present")) {
    WARN_MESSAGE(intact, "a translated side read a torn frame in a virtual machine");
  } else {
    CHECK(intact);
  }
}

bool framesMatch(const float* data, uint64_t first, uint64_t count) {
  for (uint64_t k = 0; k < count; ++k) {
    const auto value = static_cast<float>(first + k);
    if (data[2 * k] != value || data[2 * k + 1] != -value) return false;
  }
  return true;
}

bool waitUntilDead(pid_t pid) {
  const nmr::MonotonicClock clock;
  const uint64_t give_up = clock.nowNs() + 5 * kNsPerSecond;
  while (shm::processLiveness(pid, 0) != shm::Liveness::kDead) {
    if (clock.nowNs() > give_up) return false;
    ::usleep(1000);
  }
  return true;
}

int exitCode(pid_t child) {
  int status = 0;
  if (::waitpid(child, &status, 0) != child || !WIFEXITED(status)) return -1;
  return WEXITSTATUS(status);
}

// ---- Writer (a plugin instance in another process) ----

int runWriter(const std::string& prefix, uint64_t total_frames, const std::string& name) {
  shm::Status status = shm::Status::kFailed;
  const auto registry = shm::Registry::open(prefix, status);
  if (!registry) return kWriterNoRegistry;
  const nmr::MonotonicClock clock;
  // Like a plugin showing "connected": start once the app (the test's parent) beats.
  const uint64_t give_up = clock.nowNs() + 15 * kNsPerSecond;
  while (!registry->appAlive(clock.nowNs())) {
    if (clock.nowNs() > give_up) return kWriterNoApp;
    ::usleep(1000);
  }
  const uint64_t id = shm::newInstanceId();
  const auto slot = registry->claim(id, kRate, 2, name, clock, status);
  if (!slot) return kWriterNoSlot;
  const auto ring = shm::Ring::create(*registry, *slot, id, kRate, status);
  if (!ring) {
    registry->release(*slot, id);
    return kWriterNoRing;
  }

  nmr::FrameRingView view = ring->view();
  std::vector<float> left(kMaxBlock);
  std::vector<float> right(kMaxBlock);
  uint32_t seed = 7;
  for (uint64_t written = 0; written < total_frames;) {
    seed = seed * 1103515245u + 12345u;
    const auto n = static_cast<uint32_t>(
        std::min<uint64_t>((seed >> 8) % kMaxBlock + 1, total_frames - written));
    for (uint32_t k = 0; k < n; ++k) {
      left[k] = static_cast<float>(written + k);
      right[k] = -left[k];
    }
    view.writeSplit(left.data(), right.data(), n);
    if (!registry->beat(*slot, id, clock.nowNs())) return kWriterLostSlot;  // reclaimed
    written += n;
    ::usleep(20);  // a little slower than the reader, like an audio callback
  }

  // Stay listed until the app is done reading: it stops its heartbeat.
  const uint64_t linger_until = clock.nowNs() + 30 * kNsPerSecond;
  while (registry->appAlive(clock.nowNs()) && clock.nowNs() < linger_until) {
    if (!registry->beat(*slot, id, clock.nowNs())) return kWriterLostSlot;
    ::usleep(1000);
  }
  registry->release(*slot, id);
  return kWriterOk;
}

// ---- Reader (the app) ----

struct ReadReport {
  bool found = false;           // the writer's slot was listed as live
  bool owner_alive = false;     // its pid and start time named a running process
  bool clocks_agree = false;    // its heartbeat was within 1 s of this process's clock
  bool intact = true;           // every accepted frame carried its own index
  uint64_t frames_checked = 0;
  uint64_t frames_written = 0;  // the ring's counter at the end
  uint64_t lapped_reads = 0;    // the writer overwrote frames while they were copied
  uint64_t skips = 0;           // the reader fell more than a ring behind and jumped ahead
  uint32_t reclaimed = 0;       // slots the app's reclaim passes freed meanwhile
  int32_t pid = 0;
  std::string name;
};

// Beats as the app (reclaiming stale slots now and then), finds the writer's slot, maps its ring
// read-only and follows the writer to the end, discarding lapped frames and checking every other
// one. Once it stalls until it is more than a ring behind, and it pauses now and then, like an
// app thread that misses frames, so it also jumps ahead. Then it stops its heartbeat.
ReadReport readFromWriter(shm::Registry& registry, pid_t writer, uint64_t total_frames) {
  const nmr::MonotonicClock clock;
  ReadReport report;
  std::unique_ptr<shm::Ring> ring;
  std::vector<float> buffer(size_t{kReadWindow} * 2);
  uint64_t position = 0;
  uint64_t reads = 0;
  uint64_t loops = 0;
  bool stalled = false;
  const uint64_t give_up = clock.nowNs() + 60 * kNsPerSecond;
  while (clock.nowNs() < give_up) {
    const uint64_t now = clock.nowNs();
    registry.appBeat(now, ::getpid());
    if (++loops % 256 == 0) report.reclaimed += registry.reclaimDead(now);
    if (!ring) {
      if (shm::processLiveness(writer, 0) == shm::Liveness::kDead) break;  // it failed
      for (const shm::SlotInfo& info : registry.live(now)) {
        shm::Status status = shm::Status::kFailed;
        auto candidate = shm::Ring::open(registry, info.slot, status);
        // Claimed, but its ring not created yet, or still the previous owner's.
        if (!candidate || candidate->owner() != info.instance_id) continue;
        ring = std::move(candidate);
        report.found = true;
        report.pid = info.pid;
        report.name = info.name;
        report.owner_alive =
            shm::processLiveness(info.pid, info.pid_start_us) == shm::Liveness::kAlive;
        const uint64_t skew =
            info.heartbeat_ns > now ? info.heartbeat_ns - now : now - info.heartbeat_ns;
        report.clocks_agree = skew < kNsPerSecond;
        break;
      }
      if (!ring) ::usleep(200);
      continue;
    }

    const nmr::FrameRingView view = ring->view();
    const uint64_t end = view.framesWritten();
    if (position >= end) {
      if (end >= total_frames || shm::processLiveness(writer, 0) == shm::Liveness::kDead) break;
      ::sched_yield();
      continue;
    }
    const uint64_t max_window = view.capacity() - nmr::kMaxWriteChunk;
    const bool behind = end - position > max_window;
    if (behind) ++report.skips;
    const uint64_t first = behind ? end - max_window : position;
    const auto count = static_cast<uint32_t>(std::min<uint64_t>(end - first, kReadWindow));
    const uint64_t intact = view.read(first, count, buffer.data());
    const uint64_t stop = first + count;
    if (intact > first) ++report.lapped_reads;
    if (intact < stop) {
      report.intact = report.intact &&
                      framesMatch(buffer.data() + (intact - first) * 2, intact, stop - intact);
      report.frames_checked += stop - intact;
    }
    position = stop;
    ++reads;
    if (!stalled) {
      // Once: miss frames until the writer is more than a ring ahead (the writer always gets
      // there: it writes 16 rings' worth), so a later read has to skip.
      stalled = true;
      while (ring->view().framesWritten() - position <= max_window &&
             ring->view().framesWritten() < total_frames && clock.nowNs() < give_up &&
             shm::processLiveness(writer, 0) != shm::Liveness::kDead) {
        registry.appBeat(clock.nowNs(), ::getpid());
        ::usleep(500);
      }
    } else if (reads % 64 == 0) {
      ::usleep(3000);
    }
  }
  if (ring) report.frames_written = ring->view().framesWritten();
  registry.appStopped(::getpid());
  return report;
}

[[maybe_unused]] std::string executablePath() {
  uint32_t size = 0;
  ::_NSGetExecutablePath(nullptr, &size);
  std::vector<char> path(size + 1, '\0');
  if (::_NSGetExecutablePath(path.data(), &size) != 0) return {};
  return path.data();
}

// This test binary, as the writer, under the other architecture (`arch` execs in place).
[[maybe_unused]] pid_t spawnOtherArchWriter(const std::string& prefix, uint64_t frames) {
  const std::string self = executablePath();
  const std::string arch_flag = "-" + kOtherArch;
  const std::string frames_text = std::to_string(frames);
  std::vector<char*> argv = {const_cast<char*>("/usr/bin/arch"),
                             const_cast<char*>(arch_flag.c_str()),
                             const_cast<char*>(self.c_str()),
                             const_cast<char*>(nmr::test::kShmWriterFlag),
                             const_cast<char*>(prefix.c_str()),
                             const_cast<char*>(frames_text.c_str()),
                             nullptr};
  pid_t pid = -1;
  if (self.empty() ||
      ::posix_spawn(&pid, "/usr/bin/arch", nullptr, nullptr, argv.data(), environ) != 0) {
    return -1;
  }
  return pid;
}

// A child process that claims a slot and exits without releasing it. Returns the slot.
std::optional<uint32_t> claimAndDie(const std::string& prefix, pid_t& child) {
  int fds[2] = {-1, -1};
  REQUIRE(::pipe(fds) == 0);
  child = ::fork();
  REQUIRE(child >= 0);
  if (child == 0) {
    ::close(fds[0]);
    shm::Status status = shm::Status::kFailed;
    const auto registry = shm::Registry::open(prefix, status);
    const nmr::MonotonicClock clock;
    const std::optional<uint32_t> slot =
        registry ? registry->claim(shm::newInstanceId(), kRate, 2, "doomed", clock, status)
                 : std::nullopt;
    const int32_t message = slot ? static_cast<int32_t>(*slot) : -1;
    const ssize_t sent = ::write(fds[1], &message, sizeof message);
    ::_exit(sent == sizeof message ? 0 : 1);  // no release: the slot's owner is now gone
  }
  ::close(fds[1]);
  int32_t message = -1;
  const ssize_t received = ::read(fds[0], &message, sizeof message);
  ::close(fds[0]);
  REQUIRE(waitUntilDead(child));  // exited; a zombie until reaped
  if (received != sizeof message || message < 0) return std::nullopt;
  return static_cast<uint32_t>(message);
}

class InteractiveQos {
 public:
  InteractiveQos() { ::pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0); }
  ~InteractiveQos() { ::pthread_set_qos_class_self_np(QOS_CLASS_DEFAULT, 0); }
  InteractiveQos(const InteractiveQos&) = delete;
  InteractiveQos& operator=(const InteractiveQos&) = delete;
};

}  // namespace

int nmr::test::shmWriterMain(int argc, char** argv) {
  if (argc != 4) return kWriterBadArguments;
  const std::string prefix = argv[2];
  if (prefix.rfind(kTestPrefixStart, 0) != 0) return kWriterBadArguments;  // tests' segments only
  char* end = nullptr;
  const unsigned long long frames = std::strtoull(argv[3], &end, 10);
  if (end == argv[3] || *end != '\0' || frames == 0 || frames >= (1ull << 24)) {
    return kWriterBadArguments;
  }
  return runWriter(prefix, frames, kThisArch + " writer");
}

// ---- Layout and names ------------------------------------------------------------------------

TEST_CASE("shm layouts have the protocol's offsets on this architecture") {
  CHECK(offsetof(shm::RegistryHeader, magic) == 0);
  CHECK(offsetof(shm::RegistryHeader, version) == 4);
  CHECK(offsetof(shm::RegistryHeader, slot_count) == 8);
  CHECK(offsetof(shm::RegistryHeader, slot_bytes) == 12);
  CHECK(offsetof(shm::RegistryHeader, app_heartbeat_ns) == 16);
  CHECK(offsetof(shm::RegistryHeader, app_pid) == 24);
  CHECK(offsetof(shm::RegistryLayout, slots) == 64);

  CHECK(alignof(shm::RegistrySlot) == 64);
  CHECK(offsetof(shm::RegistrySlot, owner) == 0);
  CHECK(offsetof(shm::RegistrySlot, heartbeat_ns) == 8);
  CHECK(offsetof(shm::RegistrySlot, seq) == 16);
  CHECK(offsetof(shm::RegistrySlot, description) == 24);
  CHECK(offsetof(shm::SlotDescription, owner) == 0);
  CHECK(offsetof(shm::SlotDescription, pid) == 8);
  CHECK(offsetof(shm::SlotDescription, channels) == 12);
  CHECK(offsetof(shm::SlotDescription, pid_start_us) == 16);
  CHECK(offsetof(shm::SlotDescription, sample_rate) == 24);
  CHECK(offsetof(shm::SlotDescription, name) == 32);
  CHECK(offsetof(shm::SlotDescription, ring_name) == 96);

  CHECK(offsetof(shm::RingHeader, magic) == 0);
  CHECK(offsetof(shm::RingHeader, version) == 4);
  CHECK(offsetof(shm::RingHeader, capacity) == 8);
  CHECK(offsetof(shm::RingHeader, channels) == 12);
  CHECK(offsetof(shm::RingHeader, owner) == 16);
  CHECK(offsetof(shm::RingHeader, sample_rate) == 24);
  CHECK(offsetof(shm::RingLayout, counter) == 128);
  CHECK(shm::kRingDataOffset == 256);
  CHECK(shm::ringBytes(shm::kRingFrames) == 256 + 65536 * 8);
  CHECK(shm::kRingFrames >= 192000 / 4);  // at least 250 ms at 192 kHz
}

TEST_CASE("the product's segment names fit the macOS limit of 31 characters") {
  const std::string prefix = NMR_SHM_PREFIX;
  CHECK(shm::registryName(prefix) == prefix + ".reg");
  CHECK(shm::ringName(prefix, 15) == prefix + ".r15");
  CHECK(shm::registryName(prefix).size() < shm::kShmNameBytes);
  for (uint32_t slot = 0; slot < shm::kSlotCount; ++slot) {
    CHECK(shm::ringName(prefix, slot).size() < shm::kShmNameBytes);
  }

  shm::Status status = shm::Status::kOk;
  CHECK_FALSE(shm::Segment::map("/" + std::string(31, 'x'), 64,
                                shm::Segment::Mode::kCreateOrOpen, status));
  CHECK(status == shm::Status::kFailed);
  CHECK_FALSE(shm::Segment::map("no-slash", 64, shm::Segment::Mode::kCreateOrOpen, status));
  CHECK(status == shm::Status::kFailed);
  const TestPrefix missing;
  CHECK_FALSE(shm::Segment::map(shm::registryName(missing.str()), 64,
                                shm::Segment::Mode::kOpenReadOnly, status));
  CHECK(status == shm::Status::kMissing);
}

TEST_CASE("MonotonicClock reads uptime in nanoseconds, the same on every architecture") {
  const nmr::MonotonicClock clock;
  const uint64_t before = ::clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  const uint64_t now = clock.nowNs();
  const uint64_t after = ::clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  CHECK(now + 1000 >= before);
  CHECK(now <= after + 1000);
}

TEST_CASE("instance ids carry the owner's pid and differ per instance") {
  std::vector<uint64_t> ids;
  for (int i = 0; i < 10'000; ++i) ids.push_back(shm::newInstanceId());
  CHECK(std::all_of(ids.begin(), ids.end(), [](uint64_t id) {
    return shm::instancePid(id) == ::getpid() && (id & 0xffffffffu) != 0;
  }));
  std::sort(ids.begin(), ids.end());
  CHECK(std::adjacent_find(ids.begin(), ids.end()) == ids.end());
}

TEST_CASE("names are cut at a whole UTF-8 character") {
  char out[8];
  shm::copyName("abc", out, sizeof out);
  CHECK(std::string(out) == "abc");
  CHECK(out[7] == '\0');
  shm::copyName("abcdefgh", out, sizeof out);
  CHECK(std::string(out) == "abcdefg");
  shm::copyName("abcde\xc3\xa9", out, sizeof out);  // "abcdeé" fits exactly
  CHECK(std::string(out) == "abcde\xc3\xa9");
  shm::copyName("abcdef\xc3\xa9", out, sizeof out);  // "é" would be cut in two
  CHECK(std::string(out) == "abcdef");
  shm::copyName("\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", out, sizeof out);  // "日本語"
  CHECK(std::string(out) == "\xe6\x97\xa5\xe6\x9c\xac");
  char tiny[4];
  shm::copyName("a\xf0\x9f\x98\x80", tiny, sizeof tiny);  // "a😀": the emoji does not fit
  CHECK(std::string(tiny) == "a");
  shm::copyName("", tiny, sizeof tiny);
  CHECK(std::string(tiny).empty());
}

// ---- Registry --------------------------------------------------------------------------------

TEST_CASE("a claimed slot is listed with its description until it is released") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  CHECK(registry->live(clock.nowNs()).empty());

  shm::Status status = shm::Status::kFailed;
  const uint64_t id = shm::newInstanceId();
  const auto slot = registry->claim(id, 48000, 2, "Bass bus", clock, status);
  REQUIRE(slot.has_value());
  CHECK(status == shm::Status::kOk);
  CHECK(registry->owns(*slot, id));

  auto live = registry->live(clock.nowNs());
  REQUIRE(live.size() == 1);
  CHECK(live[0].slot == *slot);
  CHECK(live[0].instance_id == id);
  CHECK(live[0].pid == ::getpid());
  CHECK(live[0].pid_start_us == shm::processStartUs(::getpid()));
  CHECK(live[0].channels == 2);
  CHECK(live[0].sample_rate == 48000);
  CHECK(live[0].name == "Bass bus");
  CHECK(live[0].ring_name == shm::ringName(prefix.str(), *slot));

  // Claiming again keeps the slot and takes the new description.
  CHECK(registry->claim(id, 96000, 2, "Bass", clock, status) == slot);
  CHECK(registry->describe(*slot, id, 44100, 1, "Bass (mono)"));
  CHECK_FALSE(registry->describe(*slot, id + 1, 44100, 1, "not the owner"));
  live = registry->live(clock.nowNs());
  REQUIRE(live.size() == 1);
  CHECK(live[0].sample_rate == 44100);
  CHECK(live[0].channels == 1);
  CHECK(live[0].name == "Bass (mono)");

  registry->release(*slot, id + 1);  // not the owner: no effect
  CHECK(registry->owns(*slot, id));
  registry->release(*slot, id);
  CHECK_FALSE(registry->owns(*slot, id));
  CHECK(registry->live(clock.nowNs()).empty());
}

TEST_CASE("claims with an invalid id or format are refused") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  const uint64_t id = shm::newInstanceId();
  const uint64_t foreign = (uint64_t{static_cast<uint32_t>(::getpid() + 1)} << 32) | 1u;
  shm::Status status = shm::Status::kOk;
  CHECK_FALSE(registry->claim(0, kRate, 2, "zero", clock, status));
  CHECK(status == shm::Status::kFailed);
  CHECK_FALSE(registry->claim(foreign, kRate, 2, "another pid", clock, status));
  CHECK_FALSE(registry->claim(id, 0, 2, "no rate", clock, status));
  CHECK_FALSE(registry->claim(id, std::numeric_limits<double>::quiet_NaN(), 2, "NaN", clock,
                              status));
  CHECK_FALSE(registry->claim(id, kRate, 3, "three channels", clock, status));
  CHECK(status == shm::Status::kFailed);
  CHECK(registry->live(clock.nowNs()).empty());
}

TEST_CASE("the registry holds 16 instances and refuses a 17th") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  shm::Status status = shm::Status::kFailed;
  std::vector<uint64_t> ids;
  for (uint32_t i = 0; i < shm::kSlotCount; ++i) {
    ids.push_back(shm::newInstanceId());
    CHECK(registry->claim(ids.back(), kRate, 2, "instance", clock, status) == i);
  }
  CHECK(registry->live(clock.nowNs()).size() == shm::kSlotCount);
  CHECK_FALSE(registry->claim(shm::newInstanceId(), kRate, 2, "one too many", clock, status));
  CHECK(status == shm::Status::kFull);

  registry->release(5, ids[5]);
  const uint64_t late = shm::newInstanceId();
  CHECK(registry->claim(late, kRate, 2, "late", clock, status) == 5u);
  CHECK(status == shm::Status::kOk);
}

TEST_CASE("only slots with a heartbeat within a second are live") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  shm::Status status = shm::Status::kFailed;
  const uint64_t id = shm::newInstanceId();
  const auto slot = registry->claim(id, kRate, 2, "beating", clock, status);
  REQUIRE(slot);

  const uint64_t now = clock.nowNs();
  CHECK(registry->beat(*slot, id, now));
  CHECK(registry->live(now).size() == 1);
  CHECK(registry->live(now + shm::kLiveAgeNs / 2).size() == 1);
  CHECK(registry->live(now + 2 * shm::kLiveAgeNs).empty());  // the host stopped processing
  CHECK_FALSE(registry->beat(*slot, id + 1, now + 1));        // not the owner: nothing written
  CHECK(registry->layout().slots[*slot].heartbeat_ns.load() == now);
  CHECK(registry->beat(*slot, id, now + 5 * shm::kLiveAgeNs));  // a clock that disagrees
  CHECK(registry->live(now).empty());
  CHECK(registry->beat(*slot, id, 0));
  CHECK(registry->live(now).empty());
  CHECK(registry->owns(*slot, id));  // quiet, not stale: the owner keeps its slot
  CHECK(registry->reclaimDead(now + 10 * shm::kLiveAgeNs) == 0);
  registry->release(*slot, id);
  CHECK_FALSE(registry->beat(*slot, id, now));  // released: the audio thread must stop
}

TEST_CASE("the app heartbeat tells plugins whether the app is running") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  const uint64_t now = clock.nowNs();
  CHECK_FALSE(registry->appAlive(now));
  registry->appBeat(now, ::getpid());
  CHECK(registry->appAlive(now));
  CHECK(registry->appAlive(now + shm::kLiveAgeNs / 2));
  CHECK_FALSE(registry->appAlive(now + 2 * shm::kLiveAgeNs));
  registry->appStopped(::getpid() + 1);  // another process: no effect
  CHECK(registry->appAlive(now));
  registry->appStopped(::getpid());
  CHECK_FALSE(registry->appAlive(now));
}

TEST_CASE("the registry's bytes follow the protocol layout") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  shm::Status status = shm::Status::kFailed;
  const uint64_t id = shm::newInstanceId();
  REQUIRE(registry->claim(id, 44100, 1, "Layout", clock, status) == 0u);
  REQUIRE(registry->beat(0, id, 123'456'789));

  const void* base = &registry->layout();
  CHECK(readAt<uint32_t>(base, 0) == shm::kRegistryMagic);
  CHECK(readAt<uint32_t>(base, 4) == shm::kProtocolVersion);
  CHECK(readAt<uint32_t>(base, 8) == shm::kSlotCount);
  CHECK(readAt<uint32_t>(base, 12) == 256);
  constexpr size_t kSlot = 64;
  CHECK(readAt<uint64_t>(base, kSlot + 0) == id);
  CHECK(readAt<uint64_t>(base, kSlot + 8) == 123'456'789);
  CHECK(readAt<uint32_t>(base, kSlot + 16) % 2 == 0);  // the description is complete
  CHECK(readAt<uint64_t>(base, kSlot + 24) == id);
  CHECK(readAt<int32_t>(base, kSlot + 32) == ::getpid());
  CHECK(readAt<uint32_t>(base, kSlot + 36) == 1);
  CHECK(readAt<uint64_t>(base, kSlot + 40) == shm::processStartUs(::getpid()));
  CHECK(readAt<double>(base, kSlot + 48) == 44100);
  CHECK(std::string(static_cast<const char*>(base) + kSlot + 56) == "Layout");
  CHECK(std::string(static_cast<const char*>(base) + kSlot + 120) ==
        shm::ringName(prefix.str(), 0));
}

TEST_CASE("a registry from another protocol version is refused, not reused") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  registry->layout().header.version = shm::kProtocolVersion + 1;
  shm::Status status = shm::Status::kOk;
  CHECK(shm::Registry::open(prefix.str(), status) == nullptr);
  CHECK(status == shm::Status::kIncompatible);
  registry->layout().header.version = shm::kProtocolVersion;
  CHECK(shm::Registry::open(prefix.str(), status) != nullptr);
}

TEST_CASE("a registry whose initializer died half-way is finished by the next process") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  shm::RegistryHeader& header = registry->layout().header;
  header.magic.store(shm::kRegistryInitializingMagic);
  header.version = 0;
  header.slot_count = 0;
  header.slot_bytes = 0;
  shm::Status status = shm::Status::kFailed;
  const auto again = shm::Registry::open(prefix.str(), status);  // waits ~100 ms first
  REQUIRE(again != nullptr);
  CHECK(header.magic.load() == shm::kRegistryMagic);
  CHECK(header.version == shm::kProtocolVersion);
  CHECK(header.slot_count == shm::kSlotCount);
}

// macOS applies the mode given to shm_open as is (no umask) and cannot change it afterwards
// (fchmod fails with EINVAL), so this is what other users see.
TEST_CASE("every segment is private to its user (mode 0600)") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  shm::Status status = shm::Status::kFailed;
  const uint64_t id = shm::newInstanceId();
  const auto slot = registry->claim(id, kRate, 2, "private", clock, status);
  REQUIRE(slot);
  const auto ring = shm::Ring::create(*registry, *slot, id, kRate, status);
  REQUIRE(ring);
  for (const std::string& name :
       {shm::registryName(prefix.str()), shm::ringName(prefix.str(), *slot)}) {
    const int fd = ::shm_open(name.c_str(), O_RDONLY);
    REQUIRE(fd >= 0);
    struct stat info {};
    const int result = ::fstat(fd, &info);
    ::close(fd);
    REQUIRE(result == 0);
    CHECK((info.st_mode & 0777) == 0600);
    CHECK(info.st_uid == ::getuid());
  }
}

// ---- Liveness and reclaiming -----------------------------------------------------------------

TEST_CASE("process liveness tells running, exited, zombie and reused pids apart") {
  const auto self = static_cast<int32_t>(::getpid());
  const uint64_t start = shm::processStartUs(self);
  REQUIRE(start != 0);
  CHECK(shm::processLiveness(self, start) == shm::Liveness::kAlive);
  CHECK(shm::processLiveness(self, 0) == shm::Liveness::kAlive);
  CHECK(shm::processLiveness(self, start + 1) == shm::Liveness::kDead);  // same pid, new process
  CHECK(shm::processLiveness(0, 0) == shm::Liveness::kDead);
  CHECK(shm::processLiveness(-5, 0) == shm::Liveness::kDead);

  const pid_t child = ::fork();
  REQUIRE(child >= 0);
  if (child == 0) ::_exit(0);
  CHECK(waitUntilDead(child));  // exited but not reaped: a zombie counts as dead
  CHECK(exitCode(child) == 0);
  CHECK(shm::processLiveness(child, 0) == shm::Liveness::kDead);  // reaped: gone
}

TEST_CASE("a dead owner's slot goes to the next claim, or back to the app, once it is quiet") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  shm::Status status = shm::Status::kFailed;
  std::vector<uint64_t> ids;
  for (uint32_t i = 0; i + 1 < shm::kSlotCount; ++i) {
    ids.push_back(shm::newInstanceId());
    REQUIRE(registry->claim(ids.back(), kRate, 2, "alive", clock, status) == i);
  }
  pid_t child = -1;
  const auto dead_slot = claimAndDie(prefix.str(), child);
  REQUIRE(dead_slot == shm::kSlotCount - 1);
  CHECK(exitCode(child) == 0);  // reaped: no such process any more
  shm::RegistrySlot& slot = registry->layout().slots[*dead_slot];
  slot.heartbeat_ns.store(clock.nowNs());  // it beat just before it died

  SUBCASE("a full registry hands it to the next claim") {
    const uint64_t heir = shm::newInstanceId();
    CHECK_FALSE(registry->claim(heir, kRate, 2, "too early", clock, status));
    CHECK(status == shm::Status::kFull);
    slot.heartbeat_ns.store(clock.nowNs() - 2 * shm::kLiveAgeNs);  // quiet for two seconds
    CHECK(registry->claim(heir, kRate, 2, "heir", clock, status) == dead_slot);
    CHECK(registry->owns(*dead_slot, heir));
  }

  SUBCASE("the app reclaims it, and only it") {
    const uint64_t now = clock.nowNs();
    CHECK(registry->reclaimDead(now) == 0);  // quiet for less than a second
    const uint64_t later = now + 2 * shm::kLiveAgeNs;
    CHECK(registry->reclaimDead(later) == 1);
    CHECK(slot.owner.load() == 0);
    CHECK(registry->reclaimDead(later) == 0);  // this process's slots are quiet too, but alive
    for (uint32_t i = 0; i < ids.size(); ++i) CHECK(registry->beat(i, ids[i], clock.nowNs()));
    CHECK(registry->live(clock.nowNs()).size() == shm::kSlotCount - 1);
  }
}

TEST_CASE("an owner that died mid-description leaves a reclaimable, rewritable slot") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  shm::RegistrySlot& slot = registry->layout().slots[0];
  // A claimer that died between taking the slot and finishing its description: the owner word
  // names it, the sequence is stuck odd, its heartbeat is recent.
  const uint64_t dead_owner = (uint64_t{0x7fff0000u} << 32) | 1u;  // a pid that cannot exist
  const uint64_t now = clock.nowNs();
  slot.owner.store(dead_owner);
  slot.seq.store(3);
  slot.heartbeat_ns.store(now);
  CHECK(registry->live(now).empty());      // the description cannot be read
  CHECK(registry->reclaimDead(now) == 0);  // quiet for less than a second
  CHECK(registry->reclaimDead(now + 2 * shm::kLiveAgeNs) == 1);

  shm::Status status = shm::Status::kFailed;
  const uint64_t id = shm::newInstanceId();
  REQUIRE(registry->claim(id, kRate, 2, "after", clock, status) == 0u);
  CHECK(slot.seq.load() % 2 == 0);
  const auto live = registry->live(clock.nowNs());
  REQUIRE(live.size() == 1);
  CHECK(live[0].name == "after");
}

// ---- Concurrency and permissions -------------------------------------------------------------

TEST_CASE("a description being rewritten is never read half old, half new") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  struct Version {
    double sample_rate;
    uint32_t channels;
    const char* name;
  };
  constexpr Version kVersions[2] = {{44100, 2, "first"},
                                    {96000, 1, "second, with a longer name"}};
  shm::Status status = shm::Status::kFailed;
  const uint64_t id = shm::newInstanceId();
  const auto slot = registry->claim(id, kVersions[0].sample_rate, kVersions[0].channels,
                                    kVersions[0].name, clock, status);
  REQUIRE(slot);

  std::atomic<bool> stop{false};
  std::thread owner([&] {  // renames and re-rates itself as fast as it can
    for (uint64_t i = 1; !stop.load(std::memory_order_relaxed); ++i) {
      const Version& version = kVersions[i % 2];
      registry->describe(*slot, id, version.sample_rate, version.channels, version.name);
      if (!registry->beat(*slot, id, clock.nowNs())) break;
    }
  });
  constexpr int kReads = 20'000;
  uint64_t seen[2] = {0, 0};
  uint64_t torn = 0;
  uint64_t unlisted = 0;
  for (int read = 0; read < kReads; ++read) {
    const auto live = registry->live(clock.nowNs());
    if (live.size() != 1) {
      ++unlisted;
      continue;
    }
    bool whole = false;
    for (int k = 0; k < 2; ++k) {
      if (live[0].sample_rate == kVersions[k].sample_rate &&
          live[0].channels == kVersions[k].channels && live[0].name == kVersions[k].name) {
        ++seen[k];
        whole = true;
      }
    }
    if (!whole) ++torn;
  }
  stop.store(true, std::memory_order_relaxed);
  owner.join();
  CHECK(torn == 0);
  CHECK(seen[0] > 0);
  CHECK(seen[1] > 0);
  CHECK(unlisted < kReads / 100);  // a reader gives up only after 64 rewrites in a row
  MESSAGE("descriptions read: " << seen[0] << " + " << seen[1] << ", " << unlisted
                                << " gave up, " << torn << " torn");
}

// macOS sizes a shm object once, and while one process sizes it another one's ftruncate fails
// with EINVAL and its fstat still reads 0 (about 2% of 8-thread races here): openers must wait.
TEST_CASE("threads opening a new registry at once all get the same, initialized registry") {
  constexpr int kRounds = 25;
  constexpr size_t kThreads = 8;
  for (int round = 0; round < kRounds; ++round) {
    const TestPrefix prefix;
    std::atomic<size_t> waiting{kThreads};
    std::vector<shm::Status> statuses(kThreads, shm::Status::kFailed);
    std::vector<std::unique_ptr<shm::Registry>> registries(kThreads);
    std::vector<std::thread> threads;
    for (size_t t = 0; t < kThreads; ++t) {
      threads.emplace_back([&, t] {
        waiting.fetch_sub(1);
        while (waiting.load() > 0) std::this_thread::yield();  // start together
        registries[t] = shm::Registry::open(prefix.str(), statuses[t]);
      });
    }
    for (std::thread& thread : threads) thread.join();
    for (size_t t = 0; t < kThreads; ++t) {
      CHECK(statuses[t] == shm::Status::kOk);
      REQUIRE(registries[t] != nullptr);
      CHECK(registries[t]->layout().header.magic.load() == shm::kRegistryMagic);
      CHECK(registries[t]->layout().header.slot_count == shm::kSlotCount);
    }
    // One segment behind every mapping: a claim through one shows through all of them.
    const nmr::MonotonicClock clock;
    shm::Status status = shm::Status::kFailed;
    REQUIRE(registries[0]->claim(shm::newInstanceId(), kRate, 2, "shared", clock, status));
    for (const auto& registry : registries) CHECK(registry->live(clock.nowNs()).size() == 1);
  }
}

TEST_CASE("a segment this process may not open read-write is reported as unavailable") {
  const TestPrefix prefix;
  // Read-only for its owner, as another user's segment is for this one.
  const int fd = ::shm_open(shm::registryName(prefix.str()).c_str(), O_RDWR | O_CREAT | O_EXCL,
                            S_IRUSR);
  REQUIRE(fd >= 0);
  ::close(fd);
  shm::Status status = shm::Status::kOk;
  CHECK(shm::Registry::open(prefix.str(), status) == nullptr);
  CHECK(status == shm::Status::kUnavailable);
}

// ---- Rings -----------------------------------------------------------------------------------

TEST_CASE("a ring written by its owner is read through the app's read-only mapping") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  shm::Status status = shm::Status::kFailed;
  const uint64_t id = shm::newInstanceId();
  const auto slot = registry->claim(id, kRate, 2, "ring", clock, status);
  REQUIRE(slot);

  CHECK(shm::Ring::open(*registry, *slot, status) == nullptr);
  CHECK(status == shm::Status::kMissing);
  CHECK(shm::Ring::open(*registry, shm::kSlotCount, status) == nullptr);
  CHECK(status == shm::Status::kFailed);
  CHECK(shm::Ring::create(*registry, *slot, id + 1, kRate, status) == nullptr);  // not the owner
  CHECK(status == shm::Status::kFailed);

  const auto writer = shm::Ring::create(*registry, *slot, id, kRate, status);
  REQUIRE(writer != nullptr);
  const auto reader = shm::Ring::open(*registry, *slot, status);
  REQUIRE(reader != nullptr);
  CHECK(reader->owner() == id);
  CHECK(reader->sampleRate() == kRate);
  CHECK(reader->view().valid());
  CHECK(reader->view().capacity() == shm::kRingFrames);

  constexpr uint32_t kFrames = 1000;
  std::vector<float> left(kFrames);
  std::vector<float> right(kFrames);
  for (uint32_t k = 0; k < kFrames; ++k) {
    left[k] = static_cast<float>(k);
    right[k] = -left[k];
  }
  writer->view().writeSplit(left.data(), right.data(), kFrames);
  CHECK(reader->view().framesWritten() == kFrames);
  std::vector<float> out(size_t{kFrames} * 2);
  CHECK(reader->view().read(0, kFrames, out.data()) == 0);
  CHECK(framesMatch(out.data(), 0, kFrames));
  writer->setSampleRate(96000);
  CHECK(reader->sampleRate() == 96000);

  // The raw bytes follow the protocol layout.
  const int fd = ::shm_open(shm::ringName(prefix.str(), *slot).c_str(), O_RDONLY);
  REQUIRE(fd >= 0);
  const size_t raw_bytes = shm::kRingDataOffset + 16;
  void* raw = ::mmap(nullptr, raw_bytes, PROT_READ, MAP_SHARED, fd, 0);
  ::close(fd);
  REQUIRE(raw != MAP_FAILED);
  CHECK(readAt<uint32_t>(raw, 0) == shm::kRingMagic);
  CHECK(readAt<uint32_t>(raw, 4) == shm::kProtocolVersion);
  CHECK(readAt<uint32_t>(raw, 8) == shm::kRingFrames);
  CHECK(readAt<uint32_t>(raw, 12) == 2);
  CHECK(readAt<uint64_t>(raw, 16) == id);
  CHECK(readAt<double>(raw, 24) == 96000);
  CHECK(readAt<uint64_t>(raw, 128) == kFrames);
  CHECK(readAt<float>(raw, 256 + 8) == 1.0f);
  CHECK(readAt<float>(raw, 256 + 12) == -1.0f);
  ::munmap(raw, raw_bytes);

  // The slot's next owner reuses the ring: frames cleared, the counter never goes back.
  registry->release(*slot, id);
  CHECK(shm::Ring::create(*registry, *slot, id, kRate, status) == nullptr);  // not any more
  const uint64_t next = shm::newInstanceId();
  REQUIRE(registry->claim(next, kRate, 2, "next", clock, status) == slot);
  const auto again = shm::Ring::create(*registry, *slot, next, 44100, status);
  REQUIRE(again != nullptr);
  CHECK(reader->owner() == next);
  CHECK(reader->sampleRate() == 44100);
  CHECK(reader->view().framesWritten() == kFrames);
  CHECK(reader->view().read(0, kFrames, out.data()) == 0);
  CHECK(std::all_of(out.begin(), out.end(), [](float x) { return x == 0.0f; }));
}

TEST_CASE("a ring left by another protocol version is replaced by the slot's new owner") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const int fd = ::shm_open(shm::ringName(prefix.str(), 0).c_str(), O_RDWR | O_CREAT, 0600);
  REQUIRE(fd >= 0);
  const int sized = ::ftruncate(fd, 64 * 1024);  // smaller than this version's ring
  ::close(fd);
  REQUIRE(sized == 0);

  shm::Status status = shm::Status::kOk;
  CHECK(shm::Ring::open(*registry, 0, status) == nullptr);
  CHECK(status == shm::Status::kIncompatible);
  const uint64_t id = shm::newInstanceId();
  REQUIRE(registry->claim(id, kRate, 2, "new owner", nmr::MonotonicClock(), status) == 0u);
  const auto ring = shm::Ring::create(*registry, 0, id, kRate, status);
  REQUIRE(ring != nullptr);
  const auto reader = shm::Ring::open(*registry, 0, status);
  REQUIRE(reader != nullptr);
  CHECK(reader->owner() == id);
}

// ---- Across processes and architectures ------------------------------------------------------

TEST_CASE("frames cross from a writer process to the app intact (fork)") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const pid_t child = ::fork();
  REQUIRE(child >= 0);
  if (child == 0) ::_exit(runWriter(prefix.str(), kTransferFrames, "fork writer"));

  const ReadReport report = readFromWriter(*registry, child, kTransferFrames);
  CHECK(exitCode(child) == kWriterOk);
  CHECK(report.found);
  CHECK(report.owner_alive);
  CHECK(report.pid == child);
  CHECK(report.name == "fork writer");
  CHECK(report.clocks_agree);
  checkIntact(report.intact, sysctlFlag("sysctl.proc_translated"));
  CHECK(report.frames_checked > 0);
  CHECK(report.frames_written == kTransferFrames);
  CHECK(report.skips >= 1);
  CHECK(report.reclaimed == 0);
  CHECK(registry->live(nmr::MonotonicClock().nowNs()).empty());  // released on the way out
  MESSAGE("fork: checked " << report.frames_checked << " of " << report.frames_written
                           << " frames, " << report.lapped_reads << " lapped reads, "
                           << report.skips << " skips");
}

TEST_CASE("frames and heartbeats cross architectures intact (arm64 and x86_64 under Rosetta)") {
#ifndef NMR_TEST_CROSS_ARCH
  // CI builds the tests Universal and installs Rosetta, so a skip there means the setup broke.
  if (std::getenv("CI") != nullptr) FAIL("CI must run the cross-architecture transfer");
  MESSAGE("skipped: needs a Universal test binary and Rosetta");
#else
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const pid_t child = spawnOtherArchWriter(prefix.str(), kTransferFrames);
  REQUIRE(child > 0);

  const ReadReport report = readFromWriter(*registry, child, kTransferFrames);
  CHECK(exitCode(child) == kWriterOk);
  CHECK(report.found);
  CHECK(report.owner_alive);  // both architectures read the same process start time
  CHECK(report.name == kOtherArch + " writer");
  CHECK(report.clocks_agree);
  checkIntact(report.intact, true);  // one side is always x86_64 under Rosetta
  CHECK(report.frames_checked > 0);
  CHECK(report.frames_written == kTransferFrames);
  CHECK(report.skips >= 1);
  CHECK(report.reclaimed == 0);
  MESSAGE(kThisArch << " reading " << kOtherArch << ": checked " << report.frames_checked
                    << " of " << report.frames_written << " frames, " << report.lapped_reads
                    << " lapped reads, " << report.skips << " skips");
#endif
}

// ---- Audio-thread budget (docs/BUDGET.md) ----------------------------------------------------

TEST_CASE("RT budget: write and publish 256 stereo frames into a shared ring") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  shm::Status status = shm::Status::kFailed;
  const uint64_t id = shm::newInstanceId();
  const auto slot = registry->claim(id, kRate, 2, "benchmark", clock, status);
  REQUIRE(slot);
  const auto ring = shm::Ring::create(*registry, *slot, id, kRate, status);
  REQUIRE(ring);

  constexpr uint32_t kBlock = 256;
  constexpr int kWarmup = 20'000;
  constexpr int kRuns = 200'000;
  std::vector<float> left(kBlock);
  std::vector<float> right(kBlock);
  for (uint32_t k = 0; k < kBlock; ++k) {
    left[k] = std::sin(0.01f * static_cast<float>(k));
    right[k] = std::cos(0.013f * static_cast<float>(k));
  }
  nmr::FrameRingView view = ring->view();
  const InteractiveQos qos;  // audio threads run on performance cores
  bool owned = true;
  for (int i = 0; i < kWarmup; ++i) {
    view.writeSplit(left.data(), right.data(), kBlock);
    owned = registry->beat(*slot, id, clock.nowNs()) && owned;
  }
  std::vector<uint64_t> samples(kRuns);
  for (int i = 0; i < kRuns; ++i) {
    const uint64_t start = clock.nowNs();
    view.writeSplit(left.data(), right.data(), kBlock);
    owned = registry->beat(*slot, id, clock.nowNs()) && owned;
    samples[static_cast<size_t>(i)] = clock.nowNs() - start;
  }
  CHECK(owned);
  std::sort(samples.begin(), samples.end());
  const uint64_t p50 = samples[kRuns / 2];
  const uint64_t p99 = samples[kRuns * 99 / 100];
  MESSAGE(kThisArch << ": p50 " << p50 << " ns, p99 " << p99 << " ns, max " << samples.back()
                    << " ns (budget p50 <= 500, p99 <= 2000)");
#ifdef NDEBUG
  CHECK(p50 <= 500);
  CHECK(p99 <= 2000);
#endif
}
