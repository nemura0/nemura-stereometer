#include <nmr/frame_ring.h>

namespace nmr {

namespace {
uint32_t roundUpToPowerOfTwo(uint32_t value) {
  uint32_t size = kMaxWriteChunk * 2;
  while (size < value) size <<= 1;
  return size;
}
}  // namespace

LocalFrameRing::LocalFrameRing(uint32_t min_capacity_frames) {
  const uint32_t capacity = roundUpToPowerOfTwo(min_capacity_frames);
  counter_ = new RingCounter{};
  data_ = new float[size_t{capacity} * 2]();
  view_ = FrameRingView(counter_, data_, capacity);
}

LocalFrameRing::~LocalFrameRing() {
  delete[] data_;
  delete counter_;
}

}  // namespace nmr
