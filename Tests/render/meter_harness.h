// The offscreen harness the meter renderer's GPU tests share: a small BGRA target, read back
// after each frame, and helpers that place scope points in its pixels.
#pragma once

#import <Metal/Metal.h>

#include <nmr/meter_renderer.h>

#include <doctest/doctest.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <vector>

using nmr::DrawStyle;
using nmr::GuideLevel;
using nmr::Layout;
using nmr::MeterFrame;
using nmr::MeterRenderer;
using ScopePoint = nmr::dsp::Point;

namespace {

constexpr uint32_t kSize = 200;

struct Rgb {
  float r = 0;
  float g = 0;
  float b = 0;
  float a = 0;
  [[nodiscard]] float peak() const { return std::max({r, g, b}); }
};

class Harness {
 public:
  Harness() : device_(MTLCreateSystemDefaultDevice()) {
    if (device_ == nil) return;
    queue_ = [device_ newCommandQueue];
    renderer_ = std::make_unique<MeterRenderer>(device_, MTLPixelFormatBGRA8Unorm);
    MTLTextureDescriptor* d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:kSize
                                                          height:kSize
                                                       mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;
    target_ = [device_ newTextureWithDescriptor:d];
    readback_ = [device_ newBufferWithLength:kSize * kSize * 4
                                     options:MTLResourceStorageModeShared];
    layout_ = nmr::layout({.width = kSize, .height = kSize, .scale = 1});
  }

  [[nodiscard]] bool available() const { return device_ != nil; }
  id<MTLDevice> device() const { return device_; }
  void setLayout(const Layout& layout) { layout_ = layout; }
  MeterRenderer& renderer() { return *renderer_; }
  [[nodiscard]] const Layout& layout() const { return layout_; }

  [[nodiscard]] MeterFrame frame() const {
    MeterFrame f;
    f.layout = layout_;
    f.style = {.decay = 0, .intensity = 0.2f, .size_px = 3, .density = 1};
    f.look.solid = true;
    f.look.solid_color = {1, 1, 1};
    return f;
  }

  // Renders and waits; true when the frame was drawn.
  bool render(const MeterFrame& frame, float scale = 1) {
    id<MTLCommandBuffer> commands = [queue_ commandBuffer];
    const bool drawn = renderer_->encode(commands, target_, frame, scale);
    id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
    [blit copyFromTexture:target_
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(kSize, kSize, 1)
                        toBuffer:readback_
               destinationOffset:0
          destinationBytesPerRow:kSize * 4
        destinationBytesPerImage:kSize * kSize * 4];
    [blit endEncoding];
    [commands commit];
    [commands waitUntilCompleted];
    return drawn;
  }

  [[nodiscard]] Rgb pixel(float x, float y) const {
    const auto* bytes = static_cast<const uint8_t*>(readback_.contents);
    const size_t i = (static_cast<size_t>(y) * kSize + static_cast<size_t>(x)) * 4;
    return {bytes[i + 2] / 255.0f, bytes[i + 1] / 255.0f, bytes[i] / 255.0f,  // BGRA
            bytes[i + 3] / 255.0f};
  }

  // The scope in whole pixels, as the renderer places it.
  [[nodiscard]] nmr::Rect scope() const {
    const nmr::Rect& s = layout_.scope;
    const float x = std::round(s.x);
    const float y = std::round(s.y);
    return {x, y, std::round(s.x + s.width) - x, std::round(s.y + s.height) - y};
  }

  // Where a scope point lands, in target pixels.
  [[nodiscard]] std::array<float, 2> place(ScopePoint p) const {
    const nmr::Rect s = scope();
    const float half = MeterRenderer::kFullScale / 2;
    return {s.x + (0.5f + half * p.x) * s.width, s.y + (0.5f - half * p.y) * s.height};
  }

  // The scope Y of target pixel height `y` (row r's center is r + 0.5, its top edge r).
  [[nodiscard]] float scopeY(float y) const {
    const nmr::Rect s = scope();
    return (0.5f - (y - s.y) / s.height) / (MeterRenderer::kFullScale / 2);
  }

  [[nodiscard]] Rgb at(ScopePoint p) const {
    const auto [x, y] = place(p);
    return pixel(x, y);
  }

  id<MTLCommandQueue> queue() const { return queue_; }
  id<MTLTexture> target() const { return target_; }

 private:
  id<MTLDevice> device_;
  id<MTLCommandQueue> queue_;
  std::unique_ptr<MeterRenderer> renderer_;
  id<MTLTexture> target_;
  id<MTLBuffer> readback_;
  Layout layout_;
};

inline std::vector<ScopePoint> monoLine() {
  std::vector<ScopePoint> points;
  for (int i = 0; i <= 400; ++i) points.push_back({0, -0.9f + 1.8f * i / 400});
  return points;
}

}  // namespace

#define REQUIRE_GPU(h)                   \
  do {                                   \
    if (!(h).available()) {              \
      MESSAGE("no Metal device: skipped"); \
      return;                            \
    }                                    \
    REQUIRE((h).renderer().ready());     \
  } while (false)

namespace {

// The brightest channel `d` pixels from where `p` lands: right, left, down and up.
inline std::array<float, 4> around(const Harness& h, ScopePoint p, float d) {
  const auto [x, y] = h.place(p);
  return {h.pixel(x + d, y).peak(), h.pixel(x - d, y).peak(), h.pixel(x, y + d).peak(),
          h.pixel(x, y - d).peak()};
}

// `spot`: the points, kept alive by the caller (64 copies of one point make a bright dot).
inline MeterFrame spotFrame(const Harness& h, const std::vector<ScopePoint>& spot, float glow) {
  MeterFrame f = h.frame();
  f.points = spot;
  f.glow = glow;
  f.clear = true;
  return f;
}

}  // namespace
