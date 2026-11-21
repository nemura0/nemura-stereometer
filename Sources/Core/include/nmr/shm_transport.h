// Plugin -> app transport over POSIX shared memory (docs/PROMPT.md §4), protocol version 1.
//
// Registry `<prefix>.reg`: a header, then kSlotCount slots. A plugin instance claims a slot on
// activate (main thread), writes its frames into the slot's ring `<prefix>.r<slot>` from the
// audio thread, refreshes the slot's heartbeat there, and releases the slot on deactivate. The
// app lists slots whose heartbeat is under 1 s old, maps their rings read-only, and reclaims slots
// whose owner process has died. Every segment is created with mode 0600.
//
// Layouts have fixed offsets on arm64 and x86_64 (a Rosetta plugin talks to the arm64 app):
// static_asserts below, runtime checks in the tests on both architectures. Heartbeats are
// MonotonicClock nanoseconds, never raw mach ticks.
//
// Slot state is the `owner` word: 0 = free, otherwise the claiming instance's id, whose high 32
// bits are the owner's pid. Claiming, releasing and reclaiming are single compare-exchanges on it,
// so a process that dies at any point leaves a slot that can be reclaimed from the word alone.
// A slot is active once its description names its current owner: only that owner writes the
// description, under a sequence lock, so a reader never pairs a new owner with an old description.
// "Stale" means the owner process is gone (crash, kill) and the slot has not beaten for kLiveAgeNs:
// such slots are reclaimed by pid and start time. A live owner's quiet slot (the host stopped
// processing) is kept; it is just not listed.
#pragma once

#include <nmr/frame_ring.h>
#include <nmr/monotonic_clock.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <type_traits>
#include <vector>

namespace nmr::shm {

inline constexpr uint32_t kProtocolVersion = 1;
inline constexpr uint32_t kRegistryMagic = 0x4e4d5247;  // "NMRG"
inline constexpr uint32_t kRegistryInitializingMagic = 0x494e4954;  // "INIT": header being written
inline constexpr uint32_t kRingMagic = 0x4e4d5252;      // "NMRR"
inline constexpr uint32_t kSlotCount = 16;
inline constexpr uint32_t kRingFrames = 65536;           // power of two, >= 250 ms at 192 kHz
inline constexpr size_t kNameBytes = 64;                 // UTF-8, including the NUL
inline constexpr size_t kShmNameBytes = 32;              // macOS: 31 characters + NUL
inline constexpr uint64_t kLiveAgeNs = 1'000'000'000;    // the app lists slots beating within 1 s

static_assert(std::atomic<uint32_t>::is_always_lock_free);
static_assert(std::atomic<int32_t>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<double>::is_always_lock_free);

enum class Status : uint32_t {
  kOk = 0,
  kUnavailable,   // shared memory is blocked here (sandboxed host, another user's segment)
  kIncompatible,  // a segment from another protocol version
  kFull,          // every slot belongs to a live instance
  kMissing,       // the segment does not exist (open without create)
  kFailed,        // any other system error
};
[[nodiscard]] const char* statusText(Status status) noexcept;

[[nodiscard]] std::string registryName(std::string_view prefix);
[[nodiscard]] std::string ringName(std::string_view prefix, uint32_t slot);

// ---- Layouts (shared between processes and architectures; never reorder) -------------------

struct RegistryHeader {
  std::atomic<uint32_t> magic;  // 0 (new), kRegistryInitializingMagic, then kRegistryMagic
  uint32_t version;
  uint32_t slot_count;
  uint32_t slot_bytes;
  std::atomic<uint64_t> app_heartbeat_ns;  // refreshed by the app while it runs
  std::atomic<int32_t> app_pid;
  uint32_t reserved[9];
};
static_assert(sizeof(RegistryHeader) == 64);

// What a slot's owner publishes about itself. Copied whole under RegistrySlot::seq.
struct SlotDescription {
  uint64_t owner;          // the instance this description belongs to
  int32_t pid;
  uint32_t channels;       // source channels: 1 (sent as L = R) or 2
  uint64_t pid_start_us;   // the owner process's start time: tells a reused pid apart
  double sample_rate;
  char name[kNameBytes];
  char ring_name[kShmNameBytes];
};
static_assert(sizeof(SlotDescription) == 128);

struct alignas(64) RegistrySlot {
  std::atomic<uint64_t> owner;         // the slot's state: 0 = free, else the owner's instance id
  std::atomic<uint64_t> heartbeat_ns;  // refreshed by the owner's audio thread
  std::atomic<uint32_t> seq;           // odd while the owner rewrites `description`
  uint32_t reserved0;
  SlotDescription description;
  uint8_t reserved[104];
};
static_assert(sizeof(RegistrySlot) == 256);

struct RegistryLayout {
  RegistryHeader header;
  RegistrySlot slots[kSlotCount];
};
static_assert(sizeof(RegistryLayout) == 64 + 256 * kSlotCount);

struct RingHeader {
  std::atomic<uint32_t> magic;  // kRingMagic once initialized by the current owner
  uint32_t version;
  uint32_t capacity;  // frames; a power of two
  uint32_t channels;  // 2: interleaved float32 stereo
  std::atomic<uint64_t> owner;  // the writing instance
  std::atomic<double> sample_rate;
  uint8_t reserved[96];
};
static_assert(sizeof(RingHeader) == 128);

struct RingLayout {
  RingHeader header;    // offset 0
  RingCounter counter;  // offset 128: the 64-bit write counter on its own 128-byte line
};
static_assert(sizeof(RingLayout) == 256);
static_assert(std::is_standard_layout_v<RegistryLayout> && std::is_standard_layout_v<RingLayout>,
              "shared layouts need fixed, standard offsets");
inline constexpr size_t kRingDataOffset = sizeof(RingLayout);  // interleaved frames follow

[[nodiscard]] constexpr size_t ringBytes(uint32_t capacity_frames) noexcept {
  return kRingDataOffset + size_t{capacity_frames} * 2 * sizeof(float);
}

// ---- Segments -----------------------------------------------------------------------------

// A mapped segment. Move-only; unmaps on destruction (never unlinks).
class Segment {
 public:
  enum class Mode { kCreateOrOpen, kOpenReadWrite, kOpenReadOnly };

  Segment() = default;
  ~Segment();
  Segment(Segment&& other) noexcept;
  Segment& operator=(Segment&& other) noexcept;
  Segment(const Segment&) = delete;
  Segment& operator=(const Segment&) = delete;

  // Maps the first `size` bytes of `name`. kCreateOrOpen creates it (mode 0600) and sizes it if
  // it is new. A segment smaller than `size` (another protocol version) yields kIncompatible.
  static Segment map(const std::string& name, size_t size, Mode mode, Status& status);

  [[nodiscard]] void* data() const noexcept { return data_; }
  [[nodiscard]] size_t size() const noexcept { return size_; }
  [[nodiscard]] explicit operator bool() const noexcept { return data_ != nullptr; }

 private:
  Segment(void* data, size_t size) noexcept : data_(data), size_(size) {}
  void reset() noexcept;

  void* data_ = nullptr;
  size_t size_ = 0;
};

// ---- Registry ------------------------------------------------------------------------------

struct SlotInfo {
  uint32_t slot = 0;
  uint64_t instance_id = 0;
  int32_t pid = 0;
  uint64_t pid_start_us = 0;  // with `pid`, names the owner process (processLiveness)
  uint32_t channels = 0;
  double sample_rate = 0;
  uint64_t heartbeat_ns = 0;
  std::string name;
  std::string ring_name;
};

class Registry {
 public:
  // Maps the registry for `prefix`, creating and initializing it if needed. Non-RT.
  // kUnavailable when this process may not use it (a sandboxed host, another user's segment).
  static std::unique_ptr<Registry> open(std::string_view prefix, Status& status);

  // ---- Owner side: a plugin instance, on its main thread unless noted ----
  // Claims a free slot, or a stale one (kFull if none). `instance_id` comes from newInstanceId()
  // in this process. Claiming again with an id that already owns a slot returns that slot with
  // the new description. The name is cut at a whole UTF-8 character.
  std::optional<uint32_t> claim(uint64_t instance_id, double sample_rate, uint32_t channels,
                                std::string_view name, const MonotonicClock& clock,
                                Status& status);
  // Rewrites an owned slot's description (rename, new sample rate). False if not the owner.
  bool describe(uint32_t slot, uint64_t instance_id, double sample_rate, uint32_t channels,
                std::string_view name);
  void release(uint32_t slot, uint64_t instance_id) noexcept;
  // Audio thread: refreshes the heartbeat of an owned slot (one relaxed load, one relaxed store).
  // False, and nothing written, once `instance_id` no longer owns `slot`: the owner must then stop
  // writing to the slot's ring.
  [[nodiscard]] bool beat(uint32_t slot, uint64_t instance_id, uint64_t now_ns) noexcept;
  // Real-time safe (one relaxed load): whether `instance_id` owns `slot`.
  [[nodiscard]] bool owns(uint32_t slot, uint64_t instance_id) const noexcept;

  // ---- App side ----
  // Active slots whose heartbeat is within `max_age_ns` of `now_ns`, in slot order.
  [[nodiscard]] std::vector<SlotInfo> live(uint64_t now_ns,
                                           uint64_t max_age_ns = kLiveAgeNs) const;
  // Frees stale slots: no heartbeat within kLiveAgeNs of `now_ns`, and the owner process no
  // longer exists. Returns how many were freed.
  uint32_t reclaimDead(uint64_t now_ns) noexcept;
  // The app's own heartbeat; plugins show it as "connected".
  void appBeat(uint64_t now_ns, int32_t pid) noexcept;
  void appStopped(int32_t pid) noexcept;
  [[nodiscard]] bool appAlive(uint64_t now_ns, uint64_t max_age_ns = kLiveAgeNs) const noexcept;

  [[nodiscard]] RegistryLayout& layout() const noexcept {
    return *static_cast<RegistryLayout*>(segment_.data());
  }
  [[nodiscard]] const std::string& prefix() const noexcept { return prefix_; }

 private:
  explicit Registry(Segment segment, std::string prefix) noexcept
      : segment_(std::move(segment)), prefix_(std::move(prefix)) {}

  Segment segment_;
  std::string prefix_;
};

// ---- Rings ---------------------------------------------------------------------------------

class Ring {
 public:
  // Owner, non-RT: maps the ring of a slot that `instance_id` owns (kFailed otherwise), creating
  // it or reusing one left by a previous owner (frames cleared; the write counter never goes
  // back), and prefaults every page, so the audio thread never takes a page fault.
  static std::unique_ptr<Ring> create(const Registry& registry, uint32_t slot,
                                      uint64_t instance_id, double sample_rate, Status& status);
  // App: maps an existing, initialized ring read-only. It is the listed instance's ring once
  // owner() equals that instance's id; until then it is still the previous owner's.
  static std::unique_ptr<Ring> open(const Registry& registry, uint32_t slot, Status& status);

  // Writer side for the owner; reader side for the app (a read-only mapping: never write).
  [[nodiscard]] FrameRingView view() const noexcept { return view_; }
  [[nodiscard]] uint64_t owner() const noexcept;
  [[nodiscard]] double sampleRate() const noexcept;
  void setSampleRate(double sample_rate) noexcept;  // owner, non-RT (on re-activate)

 private:
  explicit Ring(Segment segment) noexcept;

  Segment segment_;
  FrameRingView view_;
};

// ---- Helpers -------------------------------------------------------------------------------

// A new instance id: this process's pid in the high 32 bits; below, a per-process counter that
// starts at a random value and skips 0 (unique in the process, and unlike a reused pid's).
[[nodiscard]] uint64_t newInstanceId() noexcept;
[[nodiscard]] constexpr int32_t instancePid(uint64_t instance_id) noexcept {
  return static_cast<int32_t>(instance_id >> 32);
}

enum class Liveness { kAlive, kDead, kUnknown };
// Whether process `pid`, started at `start_us` (0 = any start), still runs. Zombies are dead;
// kUnknown when the system will not say (sandbox), which callers must treat as alive.
[[nodiscard]] Liveness processLiveness(int32_t pid, uint64_t start_us) noexcept;
// Start time of a running process in microseconds since the epoch; 0 if unknown.
[[nodiscard]] uint64_t processStartUs(int32_t pid) noexcept;

// Copies `text` into `out` (NUL-terminated), cutting at a whole UTF-8 character.
void copyName(std::string_view text, char* out, size_t out_bytes) noexcept;

// Removes every segment of `prefix`. Tests only: a process that still maps a removed segment
// keeps using its own orphaned copy and never meets processes that open the name again.
void unlinkAll(std::string_view prefix) noexcept;

}  // namespace nmr::shm
