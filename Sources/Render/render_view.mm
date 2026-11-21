#import <nmr/render_view.h>

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <nmr/hello_scene.h>
#include <nmr/render_loop.h>

#include <array>
#include <memory>

namespace {
constexpr float kFallbackFramesPerSecond = 60.0f;
}

@implementation NMR_OBJC(RenderView) {
  CAMetalLayer* _metalLayer;
  std::array<float, 4> _background;
  std::unique_ptr<nmr::HelloScene> _scene;
  std::unique_ptr<nmr::RenderLoop> _loop;
  __weak NSWindow* _observedWindow;
}

- (instancetype)initWithFrame:(NSRect)frame background:(const float[4])background {
  if ((self = [super initWithFrame:frame])) {
    _background = {background[0], background[1], background[2], background[3]};
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    id<MTLDevice> device = _metalLayer.device;
    if (device != nil) {
      _scene = std::make_unique<nmr::HelloScene>(device, _metalLayer.pixelFormat, _background);
      _loop = std::make_unique<nmr::RenderLoop>(_metalLayer, *_scene);
    }
  }
  return self;
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
  if (visible && !_loop->isRunning()) {
    _loop->start([self targetFramesPerSecond]);
  } else if (!visible && _loop->isRunning()) {
    _loop->stop();
  }
}

@end
