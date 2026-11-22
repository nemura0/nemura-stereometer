// The mode picker's thumbnails: a meter look drawn offscreen by the meter's own scene and
// renderer, from the test mix (nmr/test_mix.h), so a thumbnail looks like the meter would.
// Not for the render thread of a live view (it waits for the GPU): call it off the main thread.
#pragma once

#ifdef __OBJC__
#import <Metal/Metal.h>

#include <nmr/meter_scene.h>

#include <cstdint>
#include <memory>

namespace nmr {

class ThumbnailRenderer {
 public:
  static constexpr uint32_t kMaxSide = 1024;  // pixels
  static constexpr double kSampleRate = 48000;
  static constexpr double kStartS = 2.4;   // where the mix plays correlated, before the kick
  static constexpr double kSettleS = 0.6;  // drawn before the shown frame
  static constexpr double kFrameRate = 60;

  explicit ThumbnailRenderer(id<MTLDevice> device);
  ThumbnailRenderer(const ThumbnailRenderer&) = delete;
  ThumbnailRenderer& operator=(const ThumbnailRenderer&) = delete;

  [[nodiscard]] bool ready() const noexcept { return queue_ != nil; }

  // Draws `settings` at width × height pixels (`scale`: pixels per point) and copies the last
  // frame into `bgra`: width × height × 4 bytes, premultiplied BGRA, top row first. Always the
  // same pixels for the same arguments. False when nothing was drawn (a size of 0 or over
  // kMaxSide, a scale that is not positive, a NULL `bgra`, or no GPU resources).
  bool render(const MeterSettings& settings, uint32_t width, uint32_t height, float scale,
              uint8_t* bgra);

 private:
  id<MTLDevice> device_;
  id<MTLCommandQueue> queue_;
};

}  // namespace nmr

#endif  // __OBJC__
