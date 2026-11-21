#include <nmr/shm_transport.h>

#include <fcntl.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/proc.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace nmr::shm {

namespace {

// How long a process waits for another one to finish creating a segment: 100 ms in all.
constexpr int kWaitSteps = 200;
constexpr useconds_t kWaitStepUs = 500;
constexpr int kDescriptionReadAttempts = 64;
constexpr int kClaimRounds = 3;
constexpr double kMinSampleRate = 1000;
constexpr double kMaxSampleRate = 1'000'000;

Status statusFromErrno(int error) noexcept {
  switch (error) {
    case EPERM:
    case EACCES:
      return Status::kUnavailable;
    case ENOENT:
      return Status::kMissing;
    default:
      return Status::kFailed;
  }
}

class FdGuard {
 public:
  explicit FdGuard(int fd) noexcept : fd_(fd) {}
  ~FdGuard() {
    if (fd_ >= 0) ::close(fd_);
  }
  FdGuard(const FdGuard&) = delete;
  FdGuard& operator=(const FdGuard&) = delete;

 private:
  int fd_;
};

bool validFormat(double sample_rate, uint32_t channels) noexcept {
  return std::isfinite(sample_rate) && sample_rate >= kMinSampleRate &&
         sample_rate <= kMaxSampleRate && (channels == 1 || channels == 2);
}

bool withinAge(uint64_t stamp_ns, uint64_t now_ns, uint64_t max_age_ns) noexcept {
  if (stamp_ns == 0) return false;
  const uint64_t distance = now_ns > stamp_ns ? now_ns - stamp_ns : stamp_ns - now_ns;
  return distance <= max_age_ns;
}

// ---- Slot descriptions (sequence lock; the slot's owner is the only writer) ----

bool readDescription(const RegistrySlot& slot, SlotDescription& out) noexcept {
  for (int attempt = 0; attempt < kDescriptionReadAttempts; ++attempt) {
    const uint32_t before = slot.seq.load(std::memory_order_acquire);
    if ((before & 1u) == 0) {
      std::memcpy(&out, &slot.description, sizeof(out));
      std::atomic_thread_fence(std::memory_order_acquire);
      if (slot.seq.load(std::memory_order_relaxed) == before) return true;
    }
    ::sched_yield();  // the owner is mid-write: let it finish
  }
  return false;  // rewritten throughout, or its writer died mid-write (seq stuck odd)
}

void writeDescription(RegistrySlot& slot, const SlotDescription& description) noexcept {
  // Odd while writing. Starting from an odd value (a previous owner died mid-write) still ends
  // even.
  const uint32_t odd = (slot.seq.load(std::memory_order_relaxed) + 1) | 1u;
  slot.seq.store(odd, std::memory_order_relaxed);
  std::atomic_thread_fence(std::memory_order_release);
  std::memcpy(&slot.description, &description, sizeof(description));
  slot.seq.store(odd + 1, std::memory_order_release);
}

// Everything but the ring name, which depends on the slot.
SlotDescription makeDescription(uint64_t owner, double sample_rate, uint32_t channels,
                                std::string_view name) noexcept {
  SlotDescription description{};
  description.owner = owner;
  description.pid = static_cast<int32_t>(::getpid());
  description.channels = channels;
  description.pid_start_us = processStartUs(description.pid);
  description.sample_rate = sample_rate;
  copyName(name, description.name, sizeof(description.name));
  return description;
}

// The same name as ringName(), without allocating.
void setRingName(SlotDescription& description, const std::string& prefix, uint32_t slot) noexcept {
  std::snprintf(description.ring_name, sizeof(description.ring_name), "%s.r%u", prefix.c_str(),
                slot);
}

// Stale: no heartbeat for kLiveAgeNs, and the owner process is gone. The owner's pid is in the
// owner word itself; the description adds its start time, which tells a reused pid apart.
// Requiring silence too means a process lookup that the system answers wrongly (a sandbox) can
// never take the slot of an instance that is still sending.
bool ownerDied(const RegistrySlot& slot, uint64_t owner, uint64_t now_ns) noexcept {
  if (withinAge(slot.heartbeat_ns.load(std::memory_order_relaxed), now_ns, kLiveAgeNs)) {
    return false;
  }
  SlotDescription description{};
  uint64_t start_us = 0;  // unknown: any process with that pid counts as the owner
  if (readDescription(slot, description) && description.owner == owner) {
    start_us = description.pid_start_us;
  }
  return processLiveness(instancePid(owner), start_us) == Liveness::kDead;
}

// ---- Registry header ----

void writeHeaderConstants(RegistryHeader& header) noexcept {
  header.version = kProtocolVersion;
  header.slot_count = kSlotCount;
  header.slot_bytes = sizeof(RegistrySlot);
}

// A new segment is all zeros, which is already a valid empty registry: the first process to move
// the magic off zero writes the header's constants. They are constants, so finishing an
// initialization that a crashed process left half done is safe.
uint32_t initializeHeader(RegistryHeader& header) noexcept {
  uint32_t magic = header.magic.load(std::memory_order_acquire);
  if (magic == 0) {
    if (header.magic.compare_exchange_strong(magic, kRegistryInitializingMagic,
                                             std::memory_order_acq_rel)) {
      writeHeaderConstants(header);
      header.magic.store(kRegistryMagic, std::memory_order_release);
      return kRegistryMagic;
    }
  }
  for (int step = 0; magic == kRegistryInitializingMagic && step < kWaitSteps; ++step) {
    ::usleep(kWaitStepUs);
    magic = header.magic.load(std::memory_order_acquire);
  }
  if (magic == kRegistryInitializingMagic) {
    writeHeaderConstants(header);
    header.magic.compare_exchange_strong(magic, kRegistryMagic, std::memory_order_acq_rel);
    magic = header.magic.load(std::memory_order_acquire);
  }
  return magic;
}

// ---- Processes ----

// 1: found, 0: no such process, -1: the system will not say.
int queryProcess(int32_t pid, kinfo_proc& info) noexcept {
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  size_t size = sizeof(info);
  if (::sysctl(mib, 4, &info, &size, nullptr, 0) != 0) return -1;
  return size == 0 ? 0 : 1;
}

uint64_t startUs(const kinfo_proc& info) noexcept {
  const timeval& start = info.kp_proc.p_starttime;
  return static_cast<uint64_t>(start.tv_sec) * 1'000'000u + static_cast<uint64_t>(start.tv_usec);
}

}  // namespace

const char* statusText(Status status) noexcept {
  switch (status) {
    case Status::kOk:
      return "ok";
    case Status::kUnavailable:
      return "shared memory is unavailable in this process";
    case Status::kIncompatible:
      return "incompatible protocol version";
    case Status::kFull:
      return "every slot is in use";
    case Status::kMissing:
      return "not found";
    case Status::kFailed:
      return "system error";
  }
  return "unknown";
}

std::string registryName(std::string_view prefix) { return std::string(prefix) + ".reg"; }

std::string ringName(std::string_view prefix, uint32_t slot) {
  return std::string(prefix) + ".r" + std::to_string(slot);
}

// ---- Segment ---------------------------------------------------------------------------------

Segment::~Segment() { reset(); }

Segment::Segment(Segment&& other) noexcept : data_(other.data_), size_(other.size_) {
  other.data_ = nullptr;
  other.size_ = 0;
}

Segment& Segment::operator=(Segment&& other) noexcept {
  if (this != &other) {
    reset();
    data_ = other.data_;
    size_ = other.size_;
    other.data_ = nullptr;
    other.size_ = 0;
  }
  return *this;
}

void Segment::reset() noexcept {
  if (data_ != nullptr) ::munmap(data_, size_);
  data_ = nullptr;
  size_ = 0;
}

Segment Segment::map(const std::string& name, size_t size, Mode mode, Status& status) {
  if (name.size() < 2 || name.size() >= kShmNameBytes || name.front() != '/' ||
      name.find('\0') != std::string::npos || size == 0) {
    status = Status::kFailed;
    return {};
  }
  const bool writable = mode != Mode::kOpenReadOnly;
  int flags = writable ? O_RDWR : O_RDONLY;
  if (mode == Mode::kCreateOrOpen) flags |= O_CREAT;
  const int fd = ::shm_open(name.c_str(), flags, S_IRUSR | S_IWUSR);
  if (fd < 0) {
    status = statusFromErrno(errno);
    return {};
  }
  const FdGuard guard(fd);

  struct stat info {};
  if (::fstat(fd, &info) != 0) {
    status = statusFromErrno(errno);
    return {};
  }
  if (info.st_size == 0 && mode == Mode::kCreateOrOpen) {
    // macOS sizes a shm object once. EINVAL: another process sized it, or is sizing it right now;
    // its size reads 0 until that finishes.
    if (::ftruncate(fd, static_cast<off_t>(size)) != 0 && errno != EINVAL) {
      status = statusFromErrno(errno);
      return {};
    }
    for (int step = 0;; ++step) {
      if (::fstat(fd, &info) != 0) {
        status = statusFromErrno(errno);
        return {};
      }
      if (info.st_size != 0 || step == kWaitSteps) break;
      ::usleep(kWaitStepUs);
    }
  }
  if (info.st_size == 0) {  // its creator has not sized it yet
    status = Status::kMissing;
    return {};
  }
  if (info.st_size < static_cast<off_t>(size)) {  // the kernel rounds sizes up to whole pages
    status = Status::kIncompatible;
    return {};
  }

  const int protection = writable ? PROT_READ | PROT_WRITE : PROT_READ;
  void* data = ::mmap(nullptr, size, protection, MAP_SHARED, fd, 0);
  if (data == MAP_FAILED) {
    status = statusFromErrno(errno);
    return {};
  }
  status = Status::kOk;
  return Segment(data, size);
}

// ---- Registry --------------------------------------------------------------------------------

std::unique_ptr<Registry> Registry::open(std::string_view prefix, Status& status) {
  Segment segment = Segment::map(registryName(prefix), sizeof(RegistryLayout),
                                 Segment::Mode::kCreateOrOpen, status);
  if (!segment) return nullptr;
  RegistryHeader& header = static_cast<RegistryLayout*>(segment.data())->header;
  if (initializeHeader(header) != kRegistryMagic || header.version != kProtocolVersion ||
      header.slot_count != kSlotCount || header.slot_bytes != sizeof(RegistrySlot)) {
    status = Status::kIncompatible;
    return nullptr;
  }
  status = Status::kOk;
  return std::unique_ptr<Registry>(new Registry(std::move(segment), std::string(prefix)));
}

std::optional<uint32_t> Registry::claim(uint64_t instance_id, double sample_rate,
                                        uint32_t channels, std::string_view name,
                                        const MonotonicClock& clock, Status& status) {
  if (instance_id == 0 || instancePid(instance_id) != ::getpid() ||
      !validFormat(sample_rate, channels)) {
    status = Status::kFailed;
    return std::nullopt;
  }
  for (uint32_t index = 0; index < kSlotCount; ++index) {
    if (owns(index, instance_id)) {
      describe(index, instance_id, sample_rate, channels, name);
      static_cast<void>(beat(index, instance_id, clock.nowNs()));  // owned: just checked
      status = Status::kOk;
      return index;
    }
  }
  // The slow part (the process lookup) runs before a slot is taken, which keeps the window in
  // which a crash leaves a taken but undescribed slot short. Such a slot is reclaimable anyway.
  SlotDescription description = makeDescription(instance_id, sample_rate, channels, name);
  RegistryLayout& registry = layout();
  // Free slots first, then stale ones. A few rounds absorb races with other claimers and with
  // the app reclaiming slots.
  for (int round = 0; round < kClaimRounds; ++round) {
    const uint64_t now_ns = clock.nowNs();
    for (const bool take_stale : {false, true}) {
      for (uint32_t index = 0; index < kSlotCount; ++index) {
        RegistrySlot& slot = registry.slots[index];
        uint64_t current = slot.owner.load(std::memory_order_acquire);
        const bool candidate =
            take_stale ? current != 0 && ownerDied(slot, current, now_ns) : current == 0;
        if (!candidate || !slot.owner.compare_exchange_strong(current, instance_id,
                                                              std::memory_order_acq_rel,
                                                              std::memory_order_acquire)) {
          continue;
        }
        slot.heartbeat_ns.store(clock.nowNs(), std::memory_order_relaxed);
        setRingName(description, prefix_, index);
        writeDescription(slot, description);
        status = Status::kOk;
        return index;
      }
    }
  }
  status = Status::kFull;
  return std::nullopt;
}

bool Registry::describe(uint32_t slot, uint64_t instance_id, double sample_rate,
                        uint32_t channels, std::string_view name) {
  if (!owns(slot, instance_id) || !validFormat(sample_rate, channels)) return false;
  SlotDescription description = makeDescription(instance_id, sample_rate, channels, name);
  setRingName(description, prefix_, slot);
  writeDescription(layout().slots[slot], description);
  return true;
}

void Registry::release(uint32_t slot, uint64_t instance_id) noexcept {
  if (slot >= kSlotCount || instance_id == 0) return;
  uint64_t expected = instance_id;
  layout().slots[slot].owner.compare_exchange_strong(expected, 0, std::memory_order_acq_rel,
                                                     std::memory_order_acquire);
}

bool Registry::beat(uint32_t slot, uint64_t instance_id, uint64_t now_ns) noexcept {
  if (!owns(slot, instance_id)) return false;
  layout().slots[slot].heartbeat_ns.store(now_ns, std::memory_order_relaxed);
  return true;
}

bool Registry::owns(uint32_t slot, uint64_t instance_id) const noexcept {
  return slot < kSlotCount && instance_id != 0 &&
         layout().slots[slot].owner.load(std::memory_order_relaxed) == instance_id;
}

std::vector<SlotInfo> Registry::live(uint64_t now_ns, uint64_t max_age_ns) const {
  std::vector<SlotInfo> slots;
  const RegistryLayout& registry = layout();
  for (uint32_t index = 0; index < kSlotCount; ++index) {
    const RegistrySlot& slot = registry.slots[index];
    const uint64_t owner = slot.owner.load(std::memory_order_acquire);
    if (owner == 0) continue;
    const uint64_t beat = slot.heartbeat_ns.load(std::memory_order_relaxed);
    if (!withinAge(beat, now_ns, max_age_ns)) continue;
    SlotDescription description{};
    if (!readDescription(slot, description) || description.owner != owner) continue;
    if (slot.owner.load(std::memory_order_acquire) != owner) continue;
    // Shared memory is untrusted input.
    if (!validFormat(description.sample_rate, description.channels)) continue;
    description.name[kNameBytes - 1] = '\0';
    description.ring_name[kShmNameBytes - 1] = '\0';
    slots.push_back(SlotInfo{index, owner, description.pid, description.pid_start_us,
                             description.channels, description.sample_rate, beat,
                             description.name, description.ring_name});
  }
  return slots;
}

uint32_t Registry::reclaimDead(uint64_t now_ns) noexcept {
  uint32_t freed = 0;
  for (RegistrySlot& slot : layout().slots) {
    uint64_t owner = slot.owner.load(std::memory_order_acquire);
    if (owner == 0 || !ownerDied(slot, owner, now_ns)) continue;
    if (slot.owner.compare_exchange_strong(owner, 0, std::memory_order_acq_rel,
                                           std::memory_order_acquire)) {
      ++freed;
    }
  }
  return freed;
}

void Registry::appBeat(uint64_t now_ns, int32_t pid) noexcept {
  RegistryHeader& header = layout().header;
  header.app_pid.store(pid, std::memory_order_relaxed);
  header.app_heartbeat_ns.store(now_ns, std::memory_order_release);
}

void Registry::appStopped(int32_t pid) noexcept {
  RegistryHeader& header = layout().header;
  if (header.app_pid.load(std::memory_order_relaxed) == pid) {
    header.app_heartbeat_ns.store(0, std::memory_order_release);
  }
}

bool Registry::appAlive(uint64_t now_ns, uint64_t max_age_ns) const noexcept {
  return withinAge(layout().header.app_heartbeat_ns.load(std::memory_order_acquire), now_ns,
                   max_age_ns);
}

// ---- Ring ------------------------------------------------------------------------------------

Ring::Ring(Segment segment) noexcept : segment_(std::move(segment)) {
  auto* bytes = static_cast<uint8_t*>(segment_.data());
  auto* layout = reinterpret_cast<RingLayout*>(bytes);
  view_ = FrameRingView(&layout->counter, reinterpret_cast<float*>(bytes + kRingDataOffset),
                        kRingFrames);
}

std::unique_ptr<Ring> Ring::create(const Registry& registry, uint32_t slot,
                                   uint64_t instance_id, double sample_rate, Status& status) {
  if (!registry.owns(slot, instance_id) || !validFormat(sample_rate, 2)) {
    status = Status::kFailed;
    return nullptr;
  }
  const std::string name = ringName(registry.prefix(), slot);
  const size_t bytes = ringBytes(kRingFrames);
  Segment segment = Segment::map(name, bytes, Segment::Mode::kCreateOrOpen, status);
  if (!segment && status == Status::kIncompatible) {
    // Left by another protocol version; the slot is ours in a registry of this version.
    ::shm_unlink(name.c_str());
    segment = Segment::map(name, bytes, Segment::Mode::kCreateOrOpen, status);
  }
  if (!segment) return nullptr;

  auto* base = static_cast<uint8_t*>(segment.data());
  RingHeader& header = reinterpret_cast<RingLayout*>(base)->header;
  // Dirty every page now, and wire them if the system allows it, so the audio thread never takes
  // a page fault. A previous owner's frames are cleared; the write counter is left alone, so
  // readers never see it go back.
  std::memset(base + kRingDataOffset, 0, bytes - kRingDataOffset);
  ::mlock(base, bytes);  // best effort; unmapping unwires
  header.sample_rate.store(sample_rate, std::memory_order_relaxed);
  // This version's constants. A reused ring already holds them; not rewriting them keeps readers
  // that map it from racing with plain stores.
  if (header.version != kProtocolVersion || header.capacity != kRingFrames ||
      header.channels != 2) {
    header.version = kProtocolVersion;
    header.capacity = kRingFrames;
    header.channels = 2;
  }
  // A reader that sees the new owner (acquire) also sees the cleared frames and the sample rate;
  // one that maps a new ring waits for the magic.
  header.owner.store(instance_id, std::memory_order_release);
  header.magic.store(kRingMagic, std::memory_order_release);
  status = Status::kOk;
  return std::unique_ptr<Ring>(new Ring(std::move(segment)));
}

std::unique_ptr<Ring> Ring::open(const Registry& registry, uint32_t slot, Status& status) {
  if (slot >= kSlotCount) {
    status = Status::kFailed;
    return nullptr;
  }
  Segment segment = Segment::map(ringName(registry.prefix(), slot), ringBytes(kRingFrames),
                                 Segment::Mode::kOpenReadOnly, status);
  if (!segment) return nullptr;
  const RingHeader& header = static_cast<const RingLayout*>(segment.data())->header;
  if (header.magic.load(std::memory_order_acquire) != kRingMagic) {
    status = Status::kMissing;  // not initialized yet
    return nullptr;
  }
  if (header.version != kProtocolVersion || header.capacity != kRingFrames ||
      header.channels != 2) {
    status = Status::kIncompatible;
    return nullptr;
  }
  status = Status::kOk;
  return std::unique_ptr<Ring>(new Ring(std::move(segment)));
}

uint64_t Ring::owner() const noexcept {
  return static_cast<const RingLayout*>(segment_.data())
      ->header.owner.load(std::memory_order_acquire);
}

double Ring::sampleRate() const noexcept {
  return static_cast<const RingLayout*>(segment_.data())
      ->header.sample_rate.load(std::memory_order_acquire);
}

void Ring::setSampleRate(double sample_rate) noexcept {
  static_cast<RingLayout*>(segment_.data())
      ->header.sample_rate.store(sample_rate, std::memory_order_release);
}

// ---- Helpers ---------------------------------------------------------------------------------

uint64_t newInstanceId() noexcept {
  static std::atomic<uint32_t> next{[] {
    uint32_t start = 0;
    ::arc4random_buf(&start, sizeof(start));
    return start;
  }()};
  uint32_t low = next.fetch_add(1, std::memory_order_relaxed);
  if (low == 0) low = next.fetch_add(1, std::memory_order_relaxed);
  return (uint64_t{static_cast<uint32_t>(::getpid())} << 32) | low;
}

Liveness processLiveness(int32_t pid, uint64_t start_us) noexcept {
  if (pid <= 0) return Liveness::kDead;
  kinfo_proc info{};
  const int found = queryProcess(pid, info);
  if (found < 0) return Liveness::kUnknown;
  if (found == 0 || info.kp_proc.p_stat == SZOMB) return Liveness::kDead;
  if (start_us != 0 && startUs(info) != start_us) return Liveness::kDead;  // the pid was reused
  return Liveness::kAlive;
}

uint64_t processStartUs(int32_t pid) noexcept {
  kinfo_proc info{};
  return pid > 0 && queryProcess(pid, info) == 1 ? startUs(info) : 0;
}

void copyName(std::string_view text, char* out, size_t out_bytes) noexcept {
  if (out == nullptr || out_bytes == 0) return;
  size_t length = std::min(text.size(), out_bytes - 1);
  if (length < text.size()) {
    // Back up to the first byte of the character that would be cut in two.
    while (length > 0 && (static_cast<unsigned char>(text[length]) & 0xc0u) == 0x80u) --length;
  }
  std::memcpy(out, text.data(), length);
  std::memset(out + length, 0, out_bytes - length);
}

void unlinkAll(std::string_view prefix) noexcept {
  try {
    ::shm_unlink(registryName(prefix).c_str());
    for (uint32_t slot = 0; slot < kSlotCount; ++slot) ::shm_unlink(ringName(prefix, slot).c_str());
  } catch (...) {  // std::string allocation failed: nothing to clean up then
  }
}

}  // namespace nmr::shm
