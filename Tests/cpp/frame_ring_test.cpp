#include <doctest/doctest.h>
#include <nmr/frame_ring.h>

#include <atomic>
#include <cstdint>
#include <thread>
#include <vector>

namespace {

constexpr uint64_t kValueWrap = uint64_t{1} << 24;  // floats are exact integers below 2^24

// Frame i carries (i, -i), so every frame names its own index.
void fillFrames(std::vector<float>& buffer, uint64_t first, uint32_t count) {
  buffer.resize(size_t{count} * 2);
  for (uint32_t k = 0; k < count; ++k) {
    const auto value = static_cast<float>((first + k) % kValueWrap);
    buffer[2 * k] = value;
    buffer[2 * k + 1] = -value;
  }
}

bool framesMatch(const float* data, uint64_t first, uint64_t count) {
  for (uint64_t k = 0; k < count; ++k) {
    const auto value = static_cast<float>((first + k) % kValueWrap);
    if (data[2 * k] != value || data[2 * k + 1] != -value) return false;
  }
  return true;
}

}  // namespace

TEST_CASE("LocalFrameRing rounds capacity up to a power of two of at least two chunks") {
  const nmr::LocalFrameRing tiny(1);
  CHECK(tiny.view().valid());
  CHECK(tiny.view().capacity() == nmr::kMaxWriteChunk * 2);

  const nmr::LocalFrameRing odd(nmr::kMaxWriteChunk * 3 + 1);
  CHECK(odd.view().capacity() == nmr::kMaxWriteChunk * 4);
  CHECK(odd.view().framesWritten() == 0);
}

TEST_CASE("an invalid view reports itself") {
  const nmr::FrameRingView empty;
  CHECK_FALSE(empty.valid());
  nmr::RingCounter counter;
  float data[16] = {};
  CHECK_FALSE(nmr::FrameRingView(&counter, data, 8).valid());  // below two chunks
}

TEST_CASE("frames read back exactly, across the wrap point") {
  const nmr::LocalFrameRing ring(1 << 14);
  nmr::FrameRingView view = ring.view();
  std::vector<float> in;
  std::vector<float> out;
  uint64_t written = 0;
  // Odd-sized writes walk the write position across the end of the buffer several times.
  for (uint32_t round = 0; round < 40; ++round) {
    const uint32_t n = 1000 + 37 * round;
    fillFrames(in, written, n);
    view.write(in.data(), n);
    written += n;
    REQUIRE(view.framesWritten() == written);
    out.assign(size_t{n} * 2, 0.0f);
    CHECK(view.read(written - n, n, out.data()) == written - n);
    CHECK(framesMatch(out.data(), written - n, n));
  }
}

TEST_CASE("writes longer than a chunk are split and fully published") {
  const nmr::LocalFrameRing ring(1 << 15);
  nmr::FrameRingView view = ring.view();
  constexpr uint32_t kFrames = 10000;
  std::vector<float> in;
  fillFrames(in, 0, kFrames);
  view.write(in.data(), kFrames);
  CHECK(view.framesWritten() == kFrames);
  std::vector<float> out(size_t{kFrames} * 2);
  CHECK(view.read(0, kFrames, out.data()) == 0);
  CHECK(framesMatch(out.data(), 0, kFrames));
}

TEST_CASE("writeSplit interleaves left and right, and mono duplicates left") {
  const nmr::LocalFrameRing ring(1 << 14);
  nmr::FrameRingView view = ring.view();
  // The second write wraps; each window stays within capacity - kMaxWriteChunk.
  const uint32_t n = view.capacity() / 2 + 123;
  REQUIRE(n <= view.capacity() - nmr::kMaxWriteChunk);
  std::vector<float> left(n);
  std::vector<float> right(n);
  std::vector<float> out(size_t{n} * 2);

  for (uint32_t i = 0; i < n; ++i) {
    left[i] = static_cast<float>(i);
    right[i] = -static_cast<float>(i);
  }
  view.writeSplit(left.data(), right.data(), n);
  CHECK(view.read(0, n, out.data()) == 0);
  CHECK(framesMatch(out.data(), 0, n));

  view.writeSplit(left.data(), left.data(), n);
  CHECK(view.read(n, n, out.data()) == n);
  bool mono_ok = true;
  for (uint32_t i = 0; i < n; ++i) {
    mono_ok = mono_ok && out[2 * i] == left[i] && out[2 * i + 1] == left[i];
  }
  CHECK(mono_ok);
}

TEST_CASE("a lapped read reports the oldest intact frame") {
  const nmr::LocalFrameRing ring(1);
  nmr::FrameRingView view = ring.view();
  const uint32_t capacity = view.capacity();
  std::vector<float> in;
  fillFrames(in, 0, capacity * 2);
  view.write(in.data(), capacity * 2);

  std::vector<float> out(size_t{capacity} * 2);
  // Frames from the first lap are gone; the reader is told where intact data starts.
  const uint64_t oldest_intact = uint64_t{capacity} * 2 + nmr::kMaxWriteChunk - capacity;
  CHECK(view.read(0, 1024, out.data()) == oldest_intact);

  // The newest capacity - kMaxWriteChunk frames are intact.
  const uint32_t window = capacity - nmr::kMaxWriteChunk;
  const uint64_t first = uint64_t{capacity} * 2 - window;
  CHECK(view.read(first, window, out.data()) == first);
  CHECK(framesMatch(out.data(), first, window));
}

TEST_CASE("a concurrent writer and reader never expose a torn frame") {
  const nmr::LocalFrameRing ring(1 << 14);
  nmr::FrameRingView view = ring.view();
  constexpr uint64_t kTotalFrames = uint64_t{1} << 22;
  constexpr uint32_t kWindow = 4096;
  std::atomic<bool> done{false};
  std::atomic<bool> reader_checked{false};

  // On a slow machine the reader may not get a turn before kTotalFrames are written: the writer
  // goes on (up to 64 times as long) until the reader has checked some frames.
  std::thread writer([&] {
    std::vector<float> block;
    uint64_t written = 0;
    uint32_t seed = 1;
    while (written < kTotalFrames ||
           (!reader_checked.load(std::memory_order_acquire) && written < kTotalFrames * 64)) {
      seed = seed * 1103515245u + 12345u;
      const uint32_t n = (seed >> 8) % 6000 + 1;  // 1..6000 frames: some cross a chunk
      fillFrames(block, written, n);
      view.write(block.data(), n);
      written += n;
    }
    done.store(true, std::memory_order_release);
  });

  std::vector<float> out(size_t{kWindow} * 2);
  uint64_t frames_checked = 0;
  uint64_t lapped_reads = 0;
  uint64_t iteration = 0;
  bool all_intact = true;
  while (!done.load(std::memory_order_acquire)) {
    const uint64_t end = view.framesWritten();
    // Read at varying distances behind the writer, including past the lap boundary.
    const uint64_t distance = (iteration++ * 997) % view.capacity();
    if (end < kWindow + distance) continue;
    const uint64_t first = end - kWindow - distance;
    const uint64_t intact = view.read(first, kWindow, out.data());
    if (intact > first) ++lapped_reads;
    const uint64_t window_end = first + kWindow;
    if (intact < window_end) {
      all_intact = all_intact && framesMatch(out.data() + (intact - first) * 2, intact,
                                             window_end - intact);
      frames_checked += window_end - intact;
      reader_checked.store(true, std::memory_order_release);
    }
  }
  writer.join();

  CHECK(all_intact);
  CHECK(frames_checked > 0);
  MESSAGE("checked " << frames_checked << " frames, " << lapped_reads << " lapped reads");
}
