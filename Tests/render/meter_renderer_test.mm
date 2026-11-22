// GPU smoke tests: render small frames offscreen and read pixels back.
#import <Metal/Metal.h>

#include <nmr/meter_renderer.h>

#include <doctest/doctest.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <memory>
#include <utility>
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

namespace {

// The brightest channel `d` pixels from where `p` lands: right, left, down and up.
std::array<float, 4> around(const Harness& h, ScopePoint p, float d) {
  const auto [x, y] = h.place(p);
  return {h.pixel(x + d, y).peak(), h.pixel(x - d, y).peak(), h.pixel(x, y + d).peak(),
          h.pixel(x, y - d).peak()};
}

// `spot`: the points, kept alive by the caller (64 copies of one point make a bright dot).
MeterFrame spotFrame(const Harness& h, const std::vector<ScopePoint>& spot, float glow) {
  MeterFrame f = h.frame();
  f.points = spot;
  f.glow = glow;
  f.clear = true;
  return f;
}

}  // namespace

TEST_CASE("meter renderer: glow spreads light around the trace, scaled by the amount") {
  Harness h;
  REQUIRE_GPU(h);
  const std::vector<ScopePoint> spot(64, ScopePoint{0.3f, 0.3f});
  const auto [x, y] = h.place(spot[0]);
  const auto measure = [&](float glow) {
    REQUIRE(h.render(spotFrame(h, spot, glow)));
    return std::array<float, 3>{h.pixel(x, y).peak(), h.pixel(x + 8, y).peak(),
                                h.pixel(x + 40, y).peak()};
  };
  const auto none = measure(0);
  const auto half = measure(0.5f);
  const auto full = measure(1);
  CHECK(none[0] > 0.5f);
  CHECK(none[1] < 0.01f);  // no glow: dark next to the dot
  CHECK(half[1] > 0.02f);
  CHECK(full[1] > half[1] * 1.3f);  // more glow, more light around
  CHECK(full[2] < 0.01f);  // and it stays near the trace
  CHECK(full[0] >= none[0]);
  // Out-of-range amounts are clamped; a NaN is no glow.
  CHECK(measure(5)[1] == doctest::Approx(full[1]).epsilon(0.02));
  CHECK(measure(-1)[1] == doctest::Approx(none[1]).epsilon(0.02));
  CHECK(measure(std::numeric_limits<float>::quiet_NaN())[1] < 0.01f);
}

TEST_CASE("meter renderer: glow is centered on the trace, whatever the scope's size") {
  Harness h;
  REQUIRE_GPU(h);
  // A dot at the center of a 4 × 4 pixel block (a bloom texel at scale 1), far from the
  // scope's origin, where a stretched glow would land off the dot.
  constexpr float kLocal = 114;
  const float half = MeterRenderer::kFullScale / 2;
  const auto even = [](float a, float b) { return std::abs(a - b) <= 0.08f * std::max(a, b); };
  for (const float side : {149.0f, 152.0f, 153.0f}) {  // 152 is a multiple of the divisor
    CAPTURE(side);
    Layout layout = h.layout();
    layout.scope = {20, 20, side, side};
    h.setLayout(layout);
    const ScopePoint p{(kLocal / side - 0.5f) / half, (0.5f - kLocal / side) / half};
    const std::vector<ScopePoint> spot(64, p);
    REQUIRE(h.render(spotFrame(h, spot, 1)));
    const auto light = around(h, p, 7.5f);  // pixel centers 7.5 px either side
    INFO(light[0] << " " << light[1] << " " << light[2] << " " << light[3]);
    CHECK(light[0] > 0.02f);
    CHECK(even(light[0], light[1]));
    CHECK(light[2] > 0.02f);
    CHECK(even(light[2], light[3]));
  }
}

TEST_CASE("meter renderer: glow spreads the same distance in points at any scale") {
  Harness h;
  REQUIRE_GPU(h);
  const std::vector<ScopePoint> spot(64, ScopePoint{0.3f, -0.2f});
  REQUIRE(h.render(spotFrame(h, spot, 1), 1));
  const auto one = around(h, spot[0], 24);
  REQUIRE(h.render(spotFrame(h, spot, 1), 2));
  const auto two = around(h, spot[0], 24);  // 12 pt at scale 2, 24 pt at scale 1
  for (size_t i = 0; i < one.size(); ++i) {
    CAPTURE(i);
    CHECK(one[i] < 0.01f);
    CHECK(two[i] > 0.015f);
  }
}

namespace {

struct Lit {
  int count = 0;
  float red = 0;   // summed over the lit pixels
  float blue = 0;
  float min_x = 1e9f;
  std::vector<bool> mask;
};

// The pixels in `area` brighter than the background (whole pixels whose centers lie inside).
Lit litIn(const Harness& h, const nmr::Rect& area, float threshold = 0.2f) {
  Lit lit;
  for (int y = static_cast<int>(std::ceil(area.y - 0.5f));
       y + 0.5f < area.y + area.height; ++y) {
    for (int x = static_cast<int>(std::ceil(area.x - 0.5f));
         x + 0.5f < area.x + area.width; ++x) {
      const Rgb c = h.pixel(static_cast<float>(x), static_cast<float>(y));
      const bool on = c.peak() > threshold;
      lit.mask.push_back(on);
      if (!on) continue;
      ++lit.count;
      lit.red += c.r;
      lit.blue += c.b;
      lit.min_x = std::min(lit.min_x, static_cast<float>(x));
    }
  }
  return lit;
}

MeterFrame readoutFrame(Harness& h, float correlation, float balance) {
  h.setLayout(nmr::layout({.width = kSize, .height = kSize, .scale = 1, .readouts = true}));
  MeterFrame f = h.frame();
  f.correlation = correlation;
  f.balance = balance;
  return f;
}

}  // namespace

TEST_CASE("meter renderer: readouts show the meters' values at their right") {
  Harness h;
  REQUIRE_GPU(h);
  REQUIRE(h.render(readoutFrame(h, 0.5f, 0.3322f)));  // "+0.50", "R 3.0 dB"
  const Layout& l = h.layout();
  REQUIRE_FALSE(l.correlation_readout.empty());
  REQUIRE_FALSE(l.balance_readout.empty());
  CHECK(litIn(h, l.correlation_readout).count > 6);
  CHECK(litIn(h, l.balance_readout).count > 6);
}

TEST_CASE("meter renderer: the widest readout stays inside its place, at any scale") {
  Harness h;
  REQUIRE_GPU(h);
  for (const float scale : {1.0f, 2.0f}) {
    CAPTURE(scale);
    h.setLayout(nmr::layout({.width = kSize, .height = kSize, .scale = scale, .readouts = true}));
    MeterFrame f = h.frame();
    f.correlation = -1;  // "-1.00"
    f.balance = 1;       // "R 60.0 dB"
    REQUIRE(h.render(f, scale));
    const Layout& l = h.layout();
    for (const auto& [bar, readout] : {std::pair{l.correlation, l.correlation_readout},
                                       std::pair{l.balance, l.balance_readout}}) {
      // Around the readout: the gap after the bar's (antialiased) end, the rest of the row to
      // the view's edge, and a pixel above and below.
      const float gap_x = bar.x + bar.width + 1.5f;
      const float right = readout.x + readout.width;
      CHECK(litIn(h, {gap_x, readout.y - 2, readout.x - gap_x, readout.height + 4}, 0.05f)
                .count == 0);
      CHECK(litIn(h, {right, readout.y - 2, kSize - right, readout.height + 4}, 0.05f).count ==
            0);
      CHECK(litIn(h, {readout.x, readout.y - 2, readout.width, 1.5f}, 0.05f).count == 0);
      CHECK(litIn(h, {readout.x, readout.y + readout.height + 0.5f, readout.width, 1.5f}, 0.05f)
                .count == 0);
      CHECK(litIn(h, readout).count > 6);
    }
  }
}

TEST_CASE("meter renderer: readout digits keep their places as the value changes") {
  Harness h;
  REQUIRE_GPU(h);
  REQUIRE(h.render(readoutFrame(h, 0.11f, 0)));
  const Lit ones = litIn(h, h.layout().correlation_readout);
  REQUIRE(h.render(readoutFrame(h, 0.88f, 0)));
  const Lit eights = litIn(h, h.layout().correlation_readout);
  REQUIRE(ones.count > 0);
  CHECK(ones.min_x == eights.min_x);  // the sign sits at the same place: digits are one width
}

TEST_CASE("meter renderer: readouts too small to read are not drawn, not drawn stale") {
  Harness h;
  REQUIRE_GPU(h);
  REQUIRE(h.render(readoutFrame(h, 0.5f, 0)));  // an atlas for the usual size
  Layout tiny = h.layout();
  tiny.correlation_readout.height = 2;  // digits under kMinReadoutCapPx
  tiny.balance_readout.height = 2;
  h.setLayout(tiny);
  for (int i = 0; i < 2; ++i) {  // and on the frame after, when the size is the same
    MeterFrame f = h.frame();
    f.correlation = 0.5f;
    REQUIRE(h.render(f));
    const nmr::Rect& r = tiny.correlation_readout;
    CHECK(litIn(h, {r.x, r.y - 6, r.width, r.height + 12}, 0.05f).count == 0);
  }
}

TEST_CASE("meter renderer: readouts follow the value; a negative correlation is in its color") {
  Harness h;
  REQUIRE_GPU(h);
  REQUIRE(h.render(readoutFrame(h, 0.5f, 0)));
  const Lit positive = litIn(h, h.layout().correlation_readout);
  REQUIRE(h.render(readoutFrame(h, -0.5f, 0)));
  const Lit negative = litIn(h, h.layout().correlation_readout);
  REQUIRE(positive.count > 0);
  REQUIRE(negative.count > 0);
  CHECK(positive.mask != negative.mask);
  CHECK(positive.blue >= positive.red);  // the neutral text color
  CHECK(negative.red > 1.5f * negative.blue);  // #E03C60
  REQUIRE(h.render(readoutFrame(h, 0.25f, 0)));
  CHECK(litIn(h, h.layout().correlation_readout).mask != positive.mask);
}

TEST_CASE("meter renderer: a centered balance reads C, at the readout's right") {
  Harness h;
  REQUIRE_GPU(h);
  REQUIRE(h.render(readoutFrame(h, 0, 0)));
  const nmr::Rect& r = h.layout().balance_readout;
  const Lit lit = litIn(h, r);
  CHECK(lit.count > 2);
  CHECK(lit.min_x > r.x + 0.6f * r.width);
}
