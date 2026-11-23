#include "editor.h"

#import <AppKit/AppKit.h>
#import <nmr/render_view.h>

#include <nmr/colormap.h>
#include <nmr/scene_settings.h>

#include <algorithm>
#include <string>

#include "editor_controls.h"

namespace {
// Solid editor background (DAWs cannot show transparency): near-black with a cool tint.
constexpr float kBackground[4] = {0.031f, 0.031f, 0.047f, 1.0f};
constexpr CGFloat kPanelWidth = 360;
constexpr NSTimeInterval kStatusInterval = 0.25;  // the dot follows the app within this
}  // namespace

// Owns the editor's views and answers their actions. Main thread.
@interface NMR_OBJC(EditorController) : NSObject <NSMenuDelegate>
@property(nonatomic, readonly) NSView* root;
- (instancetype)initWithHost:(nmr::plugin::Editor::Host*)host size:(NSSize)size;
- (void)setSize:(NSSize)size;
- (void)setSource:(nmr::FrameRingView)ring sampleRate:(double)sampleRate;
- (void)refresh;
- (void)close;
@end

@implementation NMR_OBJC(EditorController) {
  nmr::plugin::Editor::Host* _host;
  NSView* _root;
  NMR_OBJC(RenderView) * _meter;
  NSView* _bar;
  NSView* _dot;
  NSView* _panel;
  NSTimer* _timer;
  std::string _colormapKey;
  nmr::colormap::Table _colormap;
}

- (instancetype)initWithHost:(nmr::plugin::Editor::Host*)host size:(NSSize)size {
  if ((self = [super init])) {
    _host = host;
    const NSRect bounds = NSMakeRect(0, 0, size.width, size.height);
    // Sized only by the host's set_size: hosts resize their view before or after it, and an
    // autoresizing root would take both changes.
    _root = [[NSView alloc] initWithFrame:bounds];
    _root.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    const CGFloat bar = nmr::plugin::Editor::kBarHeight;
    _meter = [[NMR_OBJC(RenderView) alloc]
        initWithFrame:NSMakeRect(0, 0, size.width, std::max<CGFloat>(size.height - bar, 0))
           background:kBackground];
    _meter.identifier = @"meter";
    _meter.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_root addSubview:_meter];

    _bar = nmr::plugin::makeTopBar(NSMakeRect(0, size.height - bar, size.width, bar), self,
                                   @selector(changed:), @selector(toggleSettings:));
    [_root addSubview:_bar];
    _dot = [self find:@"status" in:_bar];
    nmr::plugin::fitTopBar(_bar, size.width);

    __weak NMR_OBJC(EditorController)* weak = self;
    _timer = [NSTimer timerWithTimeInterval:kStatusInterval
                                    repeats:YES
                                      block:^(NSTimer*) { [weak tick]; }];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    [self refresh];
    [self tick];
  }
  return self;
}

- (NSView*)root {
  return _root;
}

- (nullable NSView*)find:(NSString*)identifier in:(NSView*)view {
  if ([view.identifier isEqualToString:identifier]) return view;
  for (NSView* child in view.subviews) {
    if (NSView* found = [self find:identifier in:child]) return found;
  }
  return nil;
}

- (void)setSize:(NSSize)size {
  [_root setFrameSize:size];
  nmr::plugin::fitTopBar(_bar, size.width);
  [self layoutPanel];
}

- (void)layoutPanel {
  if (_panel == nil) return;
  const NSSize size = _root.bounds.size;
  const CGFloat width = std::min(kPanelWidth, size.width);
  _panel.frame = NSMakeRect(size.width - width, 0, width,
                            std::max<CGFloat>(size.height - nmr::plugin::Editor::kBarHeight, 0));
}

- (void)setSource:(nmr::FrameRingView)ring sampleRate:(double)sampleRate {
  [_meter setSource:ring sampleRate:sampleRate];
}

- (void)changed:(id)sender {
  if (_host == nullptr || ![sender isKindOfClass:[NSControl class]]) return;
  try {
    const auto changed = nmr::plugin::readControl((NSControl*)sender, _host->settings());
    if (changed && *changed != _host->settings()) _host->changeSettings(*changed);
  } catch (...) {  // out of memory: the old settings stay, and show again below
  }
  [self refresh];
  [self tick];
}

- (void)toggleSettings:(id)sender {
  if (_panel == nil) {
    try {
      _panel = nmr::plugin::makeSettingsPanel(NSZeroRect, self, @selector(changed:));
    } catch (...) {  // out of memory: no panel, the gear can try again
      return;
    }
    _panel.hidden = YES;
    [_root addSubview:_panel];
    [self layoutPanel];
    [self refresh];
  }
  _panel.hidden = !_panel.hidden;
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
  if (_host == nullptr) return;
  try {
    nmr::plugin::refillMenus(_root, _host->settings());
  } catch (...) {  // a folder that cannot be listed: the menus keep what they had
  }
}

- (void)tick {
  if (_host == nullptr || _dot == nil) return;
  nmr::plugin::showSendState(_dot, _host->sendState());
}

// Shows the instance's settings in every control and in the meter.
- (void)refresh {
  if (_host == nullptr) return;
  try {
    const nmr::settings::Settings& current = _host->settings();
    const std::string& key = current.text(nmr::settings::Id::kColormap);
    if (key != _colormapKey || _colormapKey.empty()) {
      _colormap = nmr::colormap::table(nmr::colormap::resolve(key, nmr::colormap::directory()));
      _colormapKey = key;
    }
    [_meter setSettings:nmr::meterSettings(current, nmr::SceneHost::kPlugin, _colormap)];
    nmr::plugin::showSettings(_root, current);
  } catch (...) {  // out of memory: the meter keeps its last look
  }
}

// Commits a text field being edited while the host is still there, then cuts every link back to
// this controller (controls do not retain their target, menus not their delegate) before the
// views leave: a view the host still holds can no longer reach it.
- (void)close {
  [_timer invalidate];
  _timer = nil;
  NSWindow* window = _root.window;
  if (window != nil && [window.firstResponder isKindOfClass:[NSView class]] &&
      [(NSView*)window.firstResponder isDescendantOf:_root]) {
    [window makeFirstResponder:nil];
  }
  [self disconnect:_root];
  _host = nullptr;
  [_root removeFromSuperview];
}

- (void)disconnect:(NSView*)view {
  if ([view isKindOfClass:[NSControl class]]) {
    NSControl* control = (NSControl*)view;
    control.target = nil;
    control.action = nil;
    if ([control isKindOfClass:[NSPopUpButton class]]) {
      ((NSPopUpButton*)control).menu.delegate = nil;
    }
  }
  for (NSView* child in view.subviews) [self disconnect:child];
}

@end

namespace nmr::plugin {

struct Editor::Impl {
  NMR_OBJC(EditorController) * controller = nil;
};

Editor::Editor(Host& host, uint32_t width, uint32_t height)
    : impl_(std::make_unique<Impl>()), width_(width), height_(height) {
  clampSize(width_, height_);
  impl_->controller = [[NMR_OBJC(EditorController) alloc] initWithHost:&host
                                                                   size:NSMakeSize(width_,
                                                                                   height_)];
}

Editor::~Editor() {
  [impl_->controller close];
  impl_->controller = nil;
}

bool Editor::attach(void* parent) {
  NSView* host = (__bridge NSView*)parent;
  if (host == nil) return false;
  NSView* root = impl_->controller.root;
  [root removeFromSuperview];
  root.frame = NSMakeRect(0, 0, width_, height_);
  [host addSubview:root];
  return true;
}

void Editor::setSize(uint32_t width, uint32_t height) {
  clampSize(width, height);
  width_ = width;
  height_ = height;
  [impl_->controller setSize:NSMakeSize(width_, height_)];
}

void Editor::setVisible(bool visible) { impl_->controller.root.hidden = !visible; }

// Activation may come from a host thread (some AU paths); the view is AppKit, main thread only.
void Editor::setSource(FrameRingView ring, double sample_rate) {
  if ([NSThread isMainThread]) {
    [impl_->controller setSource:ring sampleRate:sample_rate];
    return;
  }
  __weak NMR_OBJC(EditorController)* controller = impl_->controller;
  dispatch_async(dispatch_get_main_queue(), ^{
    [controller setSource:ring sampleRate:sample_rate];
  });
}

void Editor::settingsChanged() { [impl_->controller refresh]; }

void Editor::clampSize(uint32_t& width, uint32_t& height) noexcept {
  width = std::clamp(width, kMinSize, kMaxSize);
  height = std::clamp(height, kMinSize, kMaxSize);
}

}  // namespace nmr::plugin
