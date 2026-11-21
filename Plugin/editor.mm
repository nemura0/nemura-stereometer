#include "editor.h"

#import <AppKit/AppKit.h>
#import <nmr/render_view.h>

#include <algorithm>

namespace nmr::plugin {

namespace {
// Solid editor background (DAWs cannot show transparency): near-black with a cool tint.
constexpr float kBackground[4] = {0.031f, 0.031f, 0.047f, 1.0f};
}  // namespace

struct Editor::Impl {
  NMR_OBJC(RenderView) * view = nil;
};

Editor::Editor(uint32_t width, uint32_t height)
    : impl_(std::make_unique<Impl>()), width_(width), height_(height) {
  clampSize(width_, height_);
  impl_->view = [[NMR_OBJC(RenderView) alloc] initWithFrame:NSMakeRect(0, 0, width_, height_)
                                                 background:kBackground];
  impl_->view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}

Editor::~Editor() {
  [impl_->view removeFromSuperview];
  impl_->view = nil;
}

bool Editor::attach(void* parent) {
  NSView* host = (__bridge NSView*)parent;
  if (host == nil) return false;
  [impl_->view removeFromSuperview];
  impl_->view.frame = NSMakeRect(0, 0, width_, height_);
  [host addSubview:impl_->view];
  return true;
}

void Editor::setSize(uint32_t width, uint32_t height) {
  clampSize(width, height);
  width_ = width;
  height_ = height;
  [impl_->view setFrameSize:NSMakeSize(width_, height_)];
}

void Editor::setVisible(bool visible) { impl_->view.hidden = !visible; }

void Editor::clampSize(uint32_t& width, uint32_t& height) noexcept {
  width = std::clamp(width, kMinSize, kMaxSize);
  height = std::clamp(height, kMinSize, kMaxSize);
}

}  // namespace nmr::plugin
