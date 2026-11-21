// A dedicated render thread driving a CAMetalDisplayLink for one CAMetalLayer.
//
// The display link is added to the render thread's own run loop, so frame callbacks never touch
// the main thread. start()/stop() are called on the main thread; stop() joins the thread.
#pragma once

#ifdef __OBJC__
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalDisplayLink.h>
#import <QuartzCore/CAMetalLayer.h>
#endif

#include <atomic>
#include <cstdint>
#include <mutex>
#include <thread>

namespace nmr {

struct FrameTiming {
  double target_time = 0;   // CAMetalDisplayLinkUpdate.targetTimestamp (CACurrentMediaTime base)
  double present_time = 0;  // targetPresentationTimestamp
  double dt = 0;            // seconds since the previous frame's target time (clamped)
  uint64_t frame_index = 0;
};

#ifdef __OBJC__

// Draws one frame into the drawable the display link handed out. Render thread only.
class FrameDrawer {
 public:
  virtual ~FrameDrawer() = default;
  virtual void drawFrame(id<CAMetalDrawable> drawable, const FrameTiming& timing) = 0;
};

class RenderLoop {
 public:
  RenderLoop(CAMetalLayer* layer, FrameDrawer& drawer);
  ~RenderLoop();
  RenderLoop(const RenderLoop&) = delete;
  RenderLoop& operator=(const RenderLoop&) = delete;

  // Main thread. Starts the thread and the link at a fixed rate (min = max = preferred).
  void start(float frames_per_second);
  // Main thread. Invalidates the link and joins the thread. Safe to call when stopped.
  void stop();
  [[nodiscard]] bool isRunning() const noexcept { return thread_.joinable(); }

  // Main thread. Serializes drawable-size changes against frame rendering.
  void resize(CGSize drawable_size, CGFloat contents_scale);

  // Render thread (called by the display-link delegate).
  void onUpdate(CAMetalDisplayLinkUpdate* update);

 private:
  void threadMain(float frames_per_second);

  CAMetalLayer* layer_;
  FrameDrawer& drawer_;
  std::thread thread_;
  std::atomic<bool> stop_requested_{false};
  std::mutex run_loop_mutex_;  // guards run_loop_ handoff between threads
  CFRunLoopRef run_loop_ = nullptr;
  std::mutex frame_mutex_;  // held while drawing and while resizing
  double last_target_time_ = 0;
  uint64_t frame_index_ = 0;
  float frames_per_second_ = 60;
};

#endif  // __OBJC__

}  // namespace nmr
