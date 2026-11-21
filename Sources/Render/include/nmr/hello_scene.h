// Phase 0 placeholder scene: proves runtime shaders + display link + editor embedding.
// Replaced by the real meter renderer in Phase 2.
#pragma once

#ifdef __OBJC__
#import <Metal/Metal.h>

#include <nmr/render_loop.h>

#include <array>

namespace nmr {

class HelloScene final : public FrameDrawer {
 public:
  HelloScene(id<MTLDevice> device, MTLPixelFormat format, std::array<float, 4> background);
  void drawFrame(id<CAMetalDrawable> drawable, const FrameTiming& timing) override;
  [[nodiscard]] bool ready() const noexcept { return pipeline_ != nil; }

 private:
  id<MTLCommandQueue> queue_;
  id<MTLRenderPipelineState> pipeline_;
  dispatch_semaphore_t in_flight_;
  std::array<float, 4> background_;
  double time_ = 0;
};

}  // namespace nmr

#endif  // __OBJC__
