#import <nmr/render_loop.h>

#import <Foundation/Foundation.h>
#include <nmr/objc_names.h>

#include <pthread.h>
#include <sys/qos.h>

#include <algorithm>

// Forwards display-link callbacks to the C++ loop. The link holds its delegate weakly, so the
// render thread keeps a strong reference for the link's whole lifetime.
@interface NMR_OBJC(DisplayLinkTarget) : NSObject <CAMetalDisplayLinkDelegate>
- (instancetype)initWithLoop:(nmr::RenderLoop*)loop;
@end

@implementation NMR_OBJC(DisplayLinkTarget) {
  nmr::RenderLoop* _loop;
}

- (instancetype)initWithLoop:(nmr::RenderLoop*)loop {
  if ((self = [super init])) {
    _loop = loop;
  }
  return self;
}

- (void)metalDisplayLink:(CAMetalDisplayLink*)link needsUpdate:(CAMetalDisplayLinkUpdate*)update {
  _loop->onUpdate(update);
}

@end

namespace nmr {

namespace {
// Upper bound on how long the render thread sleeps between stop checks when the link is quiet.
constexpr CFTimeInterval kRunLoopSlice = 0.25;
constexpr double kMaxFrameDelta = 0.1;
}  // namespace

RenderLoop::RenderLoop(CAMetalLayer* layer, FrameDrawer& drawer) : layer_(layer), drawer_(drawer) {}

RenderLoop::~RenderLoop() { stop(); }

void RenderLoop::start(float frames_per_second) {
  if (thread_.joinable()) return;
  stop_requested_.store(false, std::memory_order_release);
  frames_per_second_ = frames_per_second;
  last_target_time_ = 0;
  thread_ = std::thread([this, frames_per_second] { threadMain(frames_per_second); });
}

void RenderLoop::stop() {
  if (!thread_.joinable()) return;
  stop_requested_.store(true, std::memory_order_release);
  {
    std::lock_guard<std::mutex> lock(run_loop_mutex_);
    if (run_loop_ != nullptr) {
      CFRunLoopStop(run_loop_);
      CFRunLoopWakeUp(run_loop_);
    }
  }
  thread_.join();
}

void RenderLoop::resize(CGSize drawable_size, CGFloat contents_scale) {
  std::lock_guard<std::mutex> lock(frame_mutex_);
  layer_.contentsScale = contents_scale;
  layer_.drawableSize = drawable_size;
}

void RenderLoop::onUpdate(CAMetalDisplayLinkUpdate* update) {
  std::lock_guard<std::mutex> lock(frame_mutex_);
  FrameTiming timing;
  timing.target_time = update.targetTimestamp;
  timing.present_time = update.targetPresentationTimestamp;
  const double nominal = 1.0 / std::max(frames_per_second_, 1.0f);
  timing.dt = last_target_time_ > 0
                  ? std::clamp(timing.target_time - last_target_time_, 0.0, kMaxFrameDelta)
                  : nominal;
  last_target_time_ = timing.target_time;
  timing.frame_index = frame_index_++;
  drawer_.drawFrame(update.drawable, timing);
}

void RenderLoop::threadMain(float frames_per_second) {
  pthread_setname_np("nmr.render");
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  @autoreleasepool {
    NMR_OBJC(DisplayLinkTarget)* target = [[NMR_OBJC(DisplayLinkTarget) alloc] initWithLoop:this];
    CAMetalDisplayLink* link = [[CAMetalDisplayLink alloc] initWithMetalLayer:layer_];
    link.delegate = target;
    link.preferredFrameRateRange =
        CAFrameRateRangeMake(frames_per_second, frames_per_second, frames_per_second);
    [link addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];

    {
      std::lock_guard<std::mutex> lock(run_loop_mutex_);
      run_loop_ = CFRunLoopGetCurrent();
    }
    while (!stop_requested_.load(std::memory_order_acquire)) {
      @autoreleasepool {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, kRunLoopSlice, true);
      }
    }
    {
      std::lock_guard<std::mutex> lock(run_loop_mutex_);
      run_loop_ = nullptr;
    }
    [link invalidate];
    link.delegate = nil;
  }
}

}  // namespace nmr
