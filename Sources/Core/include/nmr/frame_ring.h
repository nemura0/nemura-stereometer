// Single-producer / single-consumer ring of interleaved stereo float32 frames.
//
// The same algorithm runs in-process (system tap -> render thread) and across processes
// (plugin -> app over POSIX shared memory), so it operates on a caller-provided header and data
// block with a fixed layout.
//
// Writer (audio thread, real-time safe): copies frames into the slots after the current write
// count, then publishes the new count with a release store. It never blocks, allocates or calls
// into the OS. Writes are split into chunks of at most kMaxWriteChunk frames, each published
// before the next starts, so a reader can bound how far an unpublished write can reach.
//
// Reader (render thread): loads the count with acquire, copies the frames it wants, then
// re-reads the count. Any frame older than `count + kMaxWriteChunk - capacity` may have been
// overwritten while it was copied, so the reader discards it (a "lap").
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace nmr {

inline constexpr uint32_t kMaxWriteChunk = 4096;

static_assert(std::atomic<uint64_t>::is_always_lock_free,
              "the ring counter must be lock-free and address-free (it lives in shared memory)");

// Shared between processes: keep the layout fixed (checked in tests on arm64 and x86_64).
struct alignas(128) RingCounter {
  std::atomic<uint64_t> frames_written{0};
  uint8_t pad[128 - sizeof(std::atomic<uint64_t>)];
};
static_assert(sizeof(RingCounter) == 128);

// A view over externally owned ring memory. Copyable; does not own anything.
class FrameRingView {
 public:
  FrameRingView() = default;
  FrameRingView(RingCounter* counter, float* data, uint32_t capacity_frames) noexcept
      : counter_(counter), data_(data), capacity_(capacity_frames), mask_(capacity_frames - 1) {}

  [[nodiscard]] bool valid() const noexcept {
    return counter_ != nullptr && data_ != nullptr && capacity_ >= kMaxWriteChunk * 2 &&
           (capacity_ & (capacity_ - 1)) == 0;
  }
  [[nodiscard]] uint32_t capacity() const noexcept { return capacity_; }

  // Writer side. Real-time safe. `interleaved` holds `frames` stereo frames (L, R, L, R, ...).
  void write(const float* interleaved, uint32_t frames) noexcept {
    while (frames > 0) {
      const uint32_t n = frames < kMaxWriteChunk ? frames : kMaxWriteChunk;
      const uint64_t start = beginChunk();
      copyIn(start, interleaved, n);
      counter_->frames_written.store(start + n, std::memory_order_release);
      interleaved += size_t{n} * 2;
      frames -= n;
    }
  }

  // Writer side for split channels (plugin buffers). `right` may equal `left` (mono: L = R).
  // Interleaves straight into the ring slots (no stack scratch: host audio threads can have
  // small stacks).
  void writeSplit(const float* left, const float* right, uint32_t frames) noexcept {
    while (frames > 0) {
      const uint32_t n = frames < kMaxWriteChunk ? frames : kMaxWriteChunk;
      const uint64_t start = beginChunk();
      const uint32_t pos = static_cast<uint32_t>(start & mask_);
      const uint32_t first = (capacity_ - pos) < n ? (capacity_ - pos) : n;
      interleaveInto(data_ + size_t{pos} * 2, left, right, first);
      interleaveInto(data_, left + first, right + first, n - first);
      counter_->frames_written.store(start + n, std::memory_order_release);
      left += n;
      right += n;
      frames -= n;
    }
  }

  // Reader side. Total frames ever written (acquire: frames below it are readable).
  [[nodiscard]] uint64_t framesWritten() const noexcept {
    return counter_->frames_written.load(std::memory_order_acquire);
  }

  // Reader side. Copies frames [first, first + count) into `out` (interleaved). `first + count`
  // must not exceed a value previously returned by framesWritten(), and only windows of at most
  // capacity() - kMaxWriteChunk frames can be fully intact. Returns the index of the first frame
  // that is guaranteed intact; frames before it were overwritten during the copy and must be
  // discarded (it may exceed first + count: nothing is valid). A return value of `first` means
  // the whole copy is valid.
  uint64_t read(uint64_t first, uint32_t count, float* out) const noexcept {
    copyOut(first, out, count);
    std::atomic_thread_fence(std::memory_order_acquire);
    const uint64_t now = counter_->frames_written.load(std::memory_order_relaxed);
    const uint64_t reach = now + kMaxWriteChunk;  // furthest an unpublished write can reach
    const uint64_t oldest_intact = reach > capacity_ ? reach - capacity_ : 0;
    return first >= oldest_intact ? first : oldest_intact;
  }

 private:
  // Start of a write chunk. The fence keeps this chunk's slot stores from becoming visible
  // before the previous chunk's publish (arm64 may reorder a store-release with later stores;
  // free on x86_64). Without it a reader could see new slot data next to a stale count and
  // misjudge which frames are intact.
  uint64_t beginChunk() noexcept {
    const uint64_t start = counter_->frames_written.load(std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);
    return start;
  }

  static void interleaveInto(float* dst, const float* left, const float* right,
                             uint32_t n) noexcept {
    for (uint32_t i = 0; i < n; ++i) {
      dst[2 * i] = left[i];
      dst[2 * i + 1] = right[i];
    }
  }
  void copyIn(uint64_t start, const float* src, uint32_t n) noexcept {
    const uint32_t pos = static_cast<uint32_t>(start & mask_);
    const uint32_t first = (capacity_ - pos) < n ? (capacity_ - pos) : n;
    std::memcpy(data_ + size_t{pos} * 2, src, size_t{first} * 2 * sizeof(float));
    if (first < n) {
      std::memcpy(data_, src + size_t{first} * 2, size_t{n - first} * 2 * sizeof(float));
    }
  }
  void copyOut(uint64_t start, float* dst, uint32_t n) const noexcept {
    const uint32_t pos = static_cast<uint32_t>(start & mask_);
    const uint32_t first = (capacity_ - pos) < n ? (capacity_ - pos) : n;
    std::memcpy(dst, data_ + size_t{pos} * 2, size_t{first} * 2 * sizeof(float));
    if (first < n) {
      std::memcpy(dst + size_t{first} * 2, data_, size_t{n - first} * 2 * sizeof(float));
    }
  }

  RingCounter* counter_ = nullptr;
  float* data_ = nullptr;
  uint32_t capacity_ = 0;
  uint32_t mask_ = 0;
};

// An in-process ring that owns its memory (allocated once, on a non-real-time thread).
class LocalFrameRing {
 public:
  explicit LocalFrameRing(uint32_t min_capacity_frames);
  ~LocalFrameRing();
  LocalFrameRing(const LocalFrameRing&) = delete;
  LocalFrameRing& operator=(const LocalFrameRing&) = delete;

  [[nodiscard]] FrameRingView view() const noexcept { return view_; }

 private:
  RingCounter* counter_ = nullptr;
  float* data_ = nullptr;
  FrameRingView view_;
};

}  // namespace nmr
