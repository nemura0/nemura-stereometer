#import <nmr/render_view.h>

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <nmr/idle.h>
#include <nmr/meter_scene.h>
#include <nmr/render_loop.h>

#include <array>
#include <memory>
#include <vector>

namespace {
constexpr float kFallbackFramesPerSecond = 60.0f;
constexpr auto kWakeCheckNs = static_cast<uint64_t>(nmr::IdleDetector::kWakeCheckS * 1e9);
constexpr uint64_t kWakeLeewayNs = 10'000'000;
}  // namespace

@implementation NMR_OBJC(RenderView) {
  CAMetalLayer* _metalLayer;
  std::array<float, 4> _background;
  std::unique_ptr<nmr::MeterScene> _scene;
  std::unique_ptr<nmr::RenderLoop> _loop;
  __weak NSWindow* _observedWindow;
  nmr::FrameRingView _ring;
  BOOL _idle;
  uint64_t _run;  // the scene's current run; callbacks from older runs are ignored
  CGSize _drawableSize;
  dispatch_queue_t _wakeQueue;
  dispatch_source_t _wakeTimer;
}

- (instancetype)initWithFrame:(NSRect)frame background:(const float[4])background {
  if ((self = [super initWithFrame:frame])) {
    _background = {background[0], background[1], background[2], background[3]};
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    id<MTLDevice> device = _metalLayer.device;
    if (device != nil) {
      _scene = std::make_unique<nmr::MeterScene>(device, _metalLayer.pixelFormat);
      [self setSettings:nmr::MeterSettings{}];
      __weak NMR_OBJC(RenderView)* weakSelf = self;
      _scene->setCallbacks(
          ^(uint64_t run) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf sceneWentIdle:run]; });
          },
          ^(float hz, uint64_t run) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf sceneRate:hz run:run]; });
          });
      _loop = std::make_unique<nmr::RenderLoop>(_metalLayer, *_scene);
    }
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    _wakeQueue = dispatch_queue_create("nmr.render-view.wake", attr);
  }
  return self;
}

- (void)setSource:(nmr::FrameRingView)ring sampleRate:(double)sampleRate {
  [self stopWakeTimer];  // it may be reading the old ring
  _ring = ring;
  if (!_scene) return;
  // Swapped between frames: when this returns, nothing reads the old ring.
  nmr::MeterScene* scene = _scene.get();
  _loop->whilePaused(^{ scene->setSource(ring, sampleRate); });
  [self wake];
}

- (void)setSettings:(const nmr::MeterSettings&)settings {
  if (!_scene) return;
  nmr::MeterSettings own = settings;
  own.look.background = _background;
  _scene->setSettings(own);
  [self wake];  // an idle meter shows the change, then stops again
}

- (BOOL)isIdle {
  return _idle;
}

- (CALayer*)makeBackingLayer {
  // Called from -setWantsLayer: during init; the scene is created right after.
  CAMetalLayer* layer = [CAMetalLayer layer];
  layer.device = MTLCreateSystemDefaultDevice();
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer.framebufferOnly = YES;
  layer.opaque = _background[3] >= 1.0f;
  layer.maximumDrawableCount = 3;
  layer.needsDisplayOnBoundsChange = NO;
  layer.presentsWithTransaction = NO;
  _metalLayer = layer;
  return layer;
}

- (BOOL)wantsUpdateLayer {
  return YES;
}

- (void)updateLayer {
  // Content comes from the render thread only.
}

- (BOOL)isOpaque {
  return _background[3] >= 1.0f;
}

- (BOOL)isRendering {
  return _loop != nullptr && _loop->isRunning();
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self stopWakeTimer];
  if (_loop) _loop->stop();
}

#pragma mark - Lifecycle

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  if (_observedWindow != nil) {
    [center removeObserver:self
                      name:NSWindowDidChangeOcclusionStateNotification
                    object:_observedWindow];
    _observedWindow = nil;
  }
  if (self.window != nil) {
    _observedWindow = self.window;
    [center addObserver:self
               selector:@selector(windowOcclusionChanged:)
                   name:NSWindowDidChangeOcclusionStateNotification
                 object:self.window];
  }
  [self updateDrawableSize];
  [self updateRenderingState];
}

- (void)viewDidHide {
  [super viewDidHide];
  [self updateRenderingState];
}

- (void)viewDidUnhide {
  [super viewDidUnhide];
  [self updateRenderingState];
}

- (void)windowOcclusionChanged:(NSNotification*)notification {
  [self updateRenderingState];
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self updateDrawableSize];
  [self updateRenderingState];
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  [self updateDrawableSize];
}

#pragma mark - Rendering state

- (CGFloat)backingScale {
  if (self.window != nil) return self.window.backingScaleFactor;
  NSScreen* screen = NSScreen.mainScreen;
  return screen != nil ? screen.backingScaleFactor : 2.0;
}

- (void)updateDrawableSize {
  if (!_loop) return;
  const CGFloat scale = [self backingScale];
  const NSSize size = self.bounds.size;
  const CGSize drawable = CGSizeMake(MAX(1.0, size.width * scale), MAX(1.0, size.height * scale));
  _loop->resize(drawable, scale);
  if (!CGSizeEqualToSize(drawable, _drawableSize)) {
    _drawableSize = drawable;
    [self wake];  // an idle meter redraws at the new size, then stops again
  }
}

- (float)targetFramesPerSecond {
  NSScreen* screen = self.window.screen ?: NSScreen.mainScreen;
  const NSInteger maximum = screen != nil ? screen.maximumFramesPerSecond : 0;
  return maximum > 0 ? static_cast<float>(maximum) : kFallbackFramesPerSecond;
}

- (void)updateRenderingState {
  if (!_loop) return;
  NSWindow* window = self.window;
  const BOOL visible = window != nil && !self.isHiddenOrHasHiddenAncestor &&
                       (window.occlusionState & NSWindowOcclusionStateVisible) != 0 &&
                       self.bounds.size.width >= 1 && self.bounds.size.height >= 1;
  if (!visible) {
    [self stopWakeTimer];
    _idle = NO;  // shown again, it starts drawing and finds out
    _loop->stop();
  } else if (!_idle && !_loop->isRunning()) {
    const float hz = _scene->prepareStart([self targetFramesPerSecond]);
    _run = _scene->restart();
    _loop->start(hz);
  }
}

#pragma mark - Idle and rate

// The scene drew its cleared frame: stop the link and look for sound at a low rate.
- (void)sceneWentIdle:(uint64_t)run {
  if (run != _run || !_loop || !_loop->isRunning()) return;  // stale: the loop restarted since
  if (_scene->changesPending()) return;  // a change came after: it is drawn, then idle again
  _loop->stop();
  _idle = YES;
  [self startWakeTimer];
}

- (void)sceneRate:(float)hz run:(uint64_t)run {
  if (run != _run || !_loop || !_loop->isRunning()) return;
  _loop->stop();  // the link's rate is fixed: start a new one (the scene keeps its trail)
  _loop->start(hz);
}

- (void)wake {
  if (!_idle) return;
  [self stopWakeTimer];
  _idle = NO;
  [self updateRenderingState];
}

- (void)startWakeTimer {
  [self stopWakeTimer];
  if (!_ring.valid()) return;  // no source: only a new one (or settings) wakes the meter
  const nmr::FrameRingView ring = _ring;
  auto scratch = std::make_shared<std::vector<float>>(2 * size_t{nmr::MeterScene::kWakeFrames});
  // From what the meter last drew: sound in the frames it never reached counts too.
  auto seen = std::make_shared<uint64_t>(_scene->drawnFrames());
  __weak NMR_OBJC(RenderView)* weakSelf = self;
  _wakeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _wakeQueue);
  dispatch_source_set_timer(_wakeTimer, dispatch_time(DISPATCH_TIME_NOW, kWakeCheckNs),
                            kWakeCheckNs, kWakeLeewayNs);
  dispatch_source_set_event_handler(_wakeTimer, ^{
    if (!nmr::MeterScene::soundArrived(ring, *seen, scratch->data())) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf wake]; });
  });
  dispatch_resume(_wakeTimer);
}

// Returns once no check is running (a check reads the ring).
- (void)stopWakeTimer {
  if (_wakeTimer == nil) return;
  dispatch_source_cancel(_wakeTimer);
  _wakeTimer = nil;
  dispatch_sync(_wakeQueue, ^{});
}

@end
