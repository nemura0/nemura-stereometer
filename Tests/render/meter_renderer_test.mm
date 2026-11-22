// GPU smoke tests: render small frames offscreen and read pixels back.
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
  bool render(const MeterFrame& frame) {
    id<MTLCommandBuffer> commands = [queue_ commandBuffer];
    const bool drawn = renderer_->encode(commands, target_, frame);
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

std::vector<ScopePoint> monoLine() {
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

TEST_CASE("meter renderer: the background fills what is not lit") {
  Harness h;
  REQUIRE_GPU(h);
  MeterFrame f = h.frame();
  f.look.background = {0.1f, 0.2f, 0.3f, 1};
  REQUIRE(h.render(f));
  const Rgb corner = h.pixel(1, 1);
  CHECK(corner.r == doctest::Approx(0.1).epsilon(0.03));
  CHECK(corner.g == doctest::Approx(0.2).epsilon(0.03));
  CHECK(corner.b == doctest::Approx(0.3).epsilon(0.03));
  CHECK(h.at({0, 0}).b == doctest::Approx(0.3).epsilon(0.03));
}

TEST_CASE("meter renderer: dots light where the samples land, nowhere else") {
  Harness h;
  REQUIRE_GPU(h);
  const std::vector<ScopePoint> points = monoLine();
  const std::vector<float> colors(points.size(), 0.5f);
  MeterFrame f = h.frame();
  f.points = points;
  f.colors = colors;
  REQUIRE(h.render(f));
  CHECK(h.at({0, 0}).peak() > 0.5f);
  CHECK(h.at({0, 0.8f}).peak() > 0.5f);
  CHECK(h.at({0.3f, 0}).peak() < 0.02f);
  CHECK(h.at({0, 0.97f}).peak() < 0.02f);  // past the last sample
}

TEST_CASE("meter renderer: lines join consecutive samples; dots do not") {
  Harness h;
  REQUIRE_GPU(h);
  const std::vector<ScopePoint> points{{-0.6f, 0}, {0.6f, 0}};
  const std::vector<float> colors{0.5f, 0.5f};
  MeterFrame f = h.frame();
  f.points = points;
  f.colors = colors;
  f.clear = true;
  REQUIRE(h.render(f));
  CHECK(h.at({0, 0}).peak() < 0.02f);
  CHECK(h.at({-0.6f, 0}).peak() > 0.1f);
  f.draw = DrawStyle::kLines;
  f.style.size_px = 2;
  REQUIRE(h.render(f));
  CHECK(h.at({0, 0}).peak() > 0.1f);
  CHECK(h.at({0, 0.2f}).peak() < 0.02f);
}

TEST_CASE("meter renderer: lines go on from the previous frame; clear forgets it") {
  Harness h;
  REQUIRE_GPU(h);
  const std::vector<ScopePoint> first{{-0.6f, -0.6f}, {-0.3f, -0.3f}};
  const std::vector<ScopePoint> second{{0.6f, 0.6f}, {0.6f, 0.2f}};
  const std::vector<float> colors{0.5f, 0.5f};
  MeterFrame f = h.frame();
  f.draw = DrawStyle::kLines;
  f.style.size_px = 2;
  f.colors = colors;
  f.points = first;
  f.clear = true;
  REQUIRE(h.render(f));
  CHECK(h.at({0, 0}).peak() < 0.02f);  // the first line starts at the first sample
  f.points = second;
  f.clear = false;
  REQUIRE(h.render(f));
  CHECK(h.at({0, 0}).peak() > 0.1f);  // joined from (-0.3, -0.3) to (0.6, 0.6)
  f.points = first;
  REQUIRE(h.render(f));
  f.points = second;
  f.clear = true;
  REQUIRE(h.render(f));
  CHECK(h.at({0, 0}).peak() < 0.02f);
}

TEST_CASE("meter renderer: lines and soft dots are antialiased, not boxes") {
  Harness h;
  REQUIRE_GPU(h);
  // A 2 px line along the top edge of pixel row r covers rows r − 1 and r; the rows beyond,
  // whose centers are 1.5 px away, stay dark.
  const float row = std::round(h.scope().y + h.scope().height / 2);
  const std::vector<ScopePoint> line{{-0.5f, h.scopeY(row)}, {0.5f, h.scopeY(row)}};
  const std::vector<float> colors{0.5f, 0.5f};
  MeterFrame f = h.frame();
  f.draw = DrawStyle::kLines;
  f.style.size_px = 2;
  f.points = line;
  f.colors = colors;
  f.clear = true;
  REQUIRE(h.render(f));
  const float x = h.place({0, 0})[0];
  CHECK(h.pixel(x, row).peak() > 0.1f);
  CHECK(h.pixel(x, row - 1).peak() > 0.1f);
  CHECK(h.pixel(x, row + 1).peak() < 0.02f);
  CHECK(h.pixel(x, row - 2).peak() < 0.02f);
  // A soft 8 px dot: 3 px from its center it has faded to a small part of its peak.
  const std::vector<ScopePoint> dot{{0, h.scopeY(row + 0.5f)}};
  f.draw = DrawStyle::kDots;
  f.style.size_px = 8;
  f.style.intensity = 0.4f;
  f.points = dot;
  f.colors = {colors.data(), 1};
  REQUIRE(h.render(f));
  const float center = h.pixel(x, row).peak();
  CHECK(center > 0.2f);
  CHECK(h.pixel(x + 3, row).peak() < 0.4f * center);
}

TEST_CASE("meter renderer: the trail fades by the decay, and clear forgets it") {
  Harness h;
  REQUIRE_GPU(h);
  const std::vector<ScopePoint> points{{0.2f, 0.2f}};
  const std::vector<float> colors{0.5f};
  MeterFrame f = h.frame();
  f.points = points;
  f.colors = colors;
  f.style.intensity = 0.3f;
  f.style.size_px = 6;
  REQUIRE(h.render(f));
  const float lit = h.at({0.2f, 0.2f}).peak();
  CHECK(lit > 0.2f);
  MeterFrame next = f;
  next.points = {};
  next.colors = {};
  next.style.decay = 0.5f;
  REQUIRE(h.render(next));
  const float faded = h.at({0.2f, 0.2f}).peak();
  CHECK(faded > 0.02f);
  CHECK(faded < lit * 0.8f);
  next.clear = true;
  REQUIRE(h.render(next));
  CHECK(h.at({0.2f, 0.2f}).peak() < 0.02f);
}

TEST_CASE("meter renderer: guides show without sound") {
  Harness h;
  REQUIRE_GPU(h);
  const nmr::Guides guides = nmr::guides(GuideLevel::kSubtle, {});
  MeterFrame f = h.frame();
  f.guides = &guides;
  REQUIRE(h.render(f));
  CHECK(h.at({0, 0.5f}).peak() > 0.05f);    // the mono axis
  CHECK(h.at({0.25f, 0.5f}).peak() < 0.02f);
}

TEST_CASE("meter renderer: the correlation bar fills toward its value") {
  Harness h;
  REQUIRE_GPU(h);
  MeterFrame f = h.frame();
  f.correlation = 1;
  REQUIRE(h.render(f));
  const nmr::Rect bar = h.layout().correlation;
  REQUIRE_FALSE(bar.empty());
  const float y = bar.y + bar.height / 2;
  const Rgb right = h.pixel(bar.x + bar.width * 0.8f, y);
  const Rgb left = h.pixel(bar.x + bar.width * 0.2f, y);
  CHECK(right.b > 0.8f);  // #8993FF
  CHECK(right.r == doctest::Approx(0x89 / 255.0).epsilon(0.05));
  CHECK(left.peak() < 0.15f);
}

TEST_CASE("meter renderer: skips a frame rather than wait for the GPU") {
  Harness h;
  REQUIRE_GPU(h);
  const MeterFrame f = h.frame();
  std::array<id<MTLCommandBuffer>, MeterRenderer::kFramesInFlight> pending;
  for (auto& commands : pending) {
    commands = [h.queue() commandBuffer];
    CHECK(h.renderer().encode(commands, h.target(), f));
  }
  id<MTLCommandBuffer> extra = [h.queue() commandBuffer];
  CHECK_FALSE(h.renderer().encode(extra, h.target(), f));
  for (auto& commands : pending) [commands commit];
  [pending.back() waitUntilCompleted];
  [extra commit];
  [extra waitUntilCompleted];
  CHECK(h.render(f));
  // Every slot came back: three frames can be in flight again.
  for (auto& commands : pending) {
    commands = [h.queue() commandBuffer];
    CHECK(h.renderer().encode(commands, h.target(), f));
  }
  for (auto& commands : pending) [commands commit];
  [pending.back() waitUntilCompleted];
}

TEST_CASE("meter renderer: colors come from the colormap") {
  Harness h;
  REQUIRE_GPU(h);
  nmr::colormap::Table red{};
  red.fill({255, 0, 0, 255});
  h.renderer().setColormap(red);
  const std::vector<ScopePoint> points = monoLine();
  const std::vector<float> colors(points.size(), 0.3f);
  MeterFrame f = h.frame();
  f.look.solid = false;
  f.points = points;
  f.colors = colors;
  REQUIRE(h.render(f));
  const Rgb lit = h.at({0, 0});
  CHECK(lit.r > 0.5f);
  CHECK(lit.r > 2 * lit.b);  // white only where it is hottest
}

TEST_CASE("meter renderer: density adds points between samples") {
  Harness h;
  REQUIRE_GPU(h);
  const std::vector<ScopePoint> points{{-0.5f, 0}, {0.5f, 0}};
  const std::vector<float> colors{0.5f, 0.5f};
  MeterFrame f = h.frame();
  f.points = points;
  f.colors = colors;
  f.clear = true;
  f.style.density = 2;
  REQUIRE(h.render(f));
  CHECK(h.at({0, 0}).peak() > 0.1f);     // halfway
  CHECK(h.at({-0.25f, 0}).peak() < 0.02f);
}

TEST_CASE("meter renderer: over a transparent background only the light shows") {
  Harness h;
  REQUIRE_GPU(h);
  const std::vector<ScopePoint> points = monoLine();
  const std::vector<float> colors(points.size(), 0.5f);
  MeterFrame f = h.frame();
  f.points = points;
  f.colors = colors;
  REQUIRE(h.render(f));
  const Rgb lit = h.at({0, 0});
  CHECK(lit.a > 0.5f);
  CHECK(lit.peak() <= lit.a + 1.0f / 255);  // premultiplied
  CHECK(h.at({0.3f, 0}).a == 0);
  CHECK(h.pixel(1, 1).a == 0);
}

TEST_CASE("meter renderer: a new scope size starts a new trail") {
  Harness h;
  REQUIRE_GPU(h);
  const std::vector<ScopePoint> points{{0.5f, 0.5f}};
  const std::vector<float> colors{0.5f};
  MeterFrame f = h.frame();
  f.points = points;
  f.colors = colors;
  f.style.size_px = 6;
  REQUIRE(h.render(f));
  REQUIRE(h.at({0.5f, 0.5f}).peak() > 0.1f);
  h.setLayout(nmr::layout({.width = kSize, .height = kSize, .scale = 1, .half = true}));
  MeterFrame next = h.frame();
  next.style.decay = 1;  // keep everything: only the new texture can lose the old light
  REQUIRE(h.render(next));
  for (const ScopePoint p : {ScopePoint{0.5f, 0.5f}, ScopePoint{0.5f, 0.0f}}) {
    CHECK(h.at(p).peak() < 0.02f);
  }
}

TEST_CASE("meter renderer: the balance bar fills toward the louder side") {
  Harness h;
  REQUIRE_GPU(h);
  MeterFrame f = h.frame();
  f.balance = -1;
  REQUIRE(h.render(f));
  const nmr::Rect bar = h.layout().balance;
  REQUIRE_FALSE(bar.empty());
  const float y = bar.y + bar.height / 2;
  CHECK(h.pixel(bar.x + bar.width * 0.2f, y).b > 0.8f);
  CHECK(h.pixel(bar.x + bar.width * 0.8f, y).peak() < 0.15f);
}

TEST_CASE("meter renderer: too many points keep the newest, not joined across the gap") {
  Harness h;
  REQUIRE_GPU(h);
  MeterFrame f = h.frame();
  f.draw = DrawStyle::kLines;
  f.style.size_px = 2;
  f.style.intensity = 0.05f;
  const std::vector<ScopePoint> before{{0.6f, 0.6f}, {0.6f, 0.5f}};
  const std::vector<float> two{0.5f, 0.5f};
  f.points = before;
  f.colors = two;
  f.clear = true;
  REQUIRE(h.render(f));
  std::vector<ScopePoint> many(MeterRenderer::kMaxPoints + 10, ScopePoint{-0.6f, -0.6f});
  for (size_t i = 0; i < 10; ++i) many[i] = {0.6f, -0.6f};  // the oldest: left out
  const std::vector<float> colors(many.size(), 0.5f);
  f.points = many;
  f.colors = colors;
  f.clear = false;
  f.style.decay = 1;
  REQUIRE(h.render(f));
  CHECK(h.at({-0.6f, -0.6f}).peak() > 0.1f);
  CHECK(h.at({0.6f, -0.6f}).peak() < 0.02f);
  CHECK(h.at({0, -0.05f}).peak() < 0.02f);  // no line from (0.6, 0.5) across to the newest
}

TEST_CASE("meter renderer: a target of another format is refused") {
  Harness h;
  REQUIRE_GPU(h);
  MTLTextureDescriptor* d =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                         width:16
                                                        height:16
                                                     mipmapped:NO];
  d.usage = MTLTextureUsageRenderTarget;
  d.storageMode = MTLStorageModePrivate;
  id<MTLTexture> other = [h.device() newTextureWithDescriptor:d];
  id<MTLCommandBuffer> commands = [h.queue() commandBuffer];
  CHECK_FALSE(h.renderer().encode(commands, other, h.frame()));
}

TEST_CASE("meter renderer: a clear asked for in a skipped frame is kept for the next") {
  Harness h;
  REQUIRE_GPU(h);
  const std::vector<ScopePoint> points{{0.3f, 0.3f}};
  const std::vector<float> colors{0.5f};
  MeterFrame f = h.frame();
  f.points = points;
  f.colors = colors;
  f.style.size_px = 6;
  REQUIRE(h.render(f));
  REQUIRE(h.at({0.3f, 0.3f}).peak() > 0.1f);
  MeterFrame keep = h.frame();
  keep.style.decay = 1;
  std::array<id<MTLCommandBuffer>, MeterRenderer::kFramesInFlight> pending;
  for (auto& commands : pending) {
    commands = [h.queue() commandBuffer];
    REQUIRE(h.renderer().encode(commands, h.target(), keep));
  }
  MeterFrame clear = keep;
  clear.clear = true;
  id<MTLCommandBuffer> skipped = [h.queue() commandBuffer];
  REQUIRE_FALSE(h.renderer().encode(skipped, h.target(), clear));
  for (auto& commands : pending) [commands commit];
  [pending.back() waitUntilCompleted];
  REQUIRE(h.render(keep));
  CHECK(h.at({0.3f, 0.3f}).peak() < 0.02f);
}
