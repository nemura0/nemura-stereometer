// GPU smoke tests: render small frames offscreen and read pixels back.
#include "meter_harness.h"

#include <limits>
#include <utility>

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
  // A soft 8 px dot: round, not a box (dim at its box's corner), fading out at its edge.
  const std::vector<ScopePoint> dot{{0, h.scopeY(row + 0.5f)}};
  f.draw = DrawStyle::kDots;
  f.style.size_px = 8;
  f.style.intensity = 0.4f;
  f.points = dot;
  f.colors = {colors.data(), 1};
  REQUIRE(h.render(f));
  const float center = h.pixel(x, row).peak();
  CHECK(center > 0.2f);
  const float edge = h.pixel(x + 3, row).peak();  // 3.5 px out, inside its edge: fading
  INFO(center << " → " << edge);
  CHECK(edge > 0.02f);
  CHECK(edge < 0.95f * center);
  CHECK(h.pixel(x + 3, row + 3).peak() < 0.3f * center);  // a box's corner, 4.6 px out
  CHECK(h.pixel(x + 5, row).peak() < 0.02f);              // and nothing past the edge
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
  const auto one = around(h, spot[0], 6);  // 6 pt at scale 1…
  const auto far = around(h, spot[0], 24);
  REQUIRE(h.render(spotFrame(h, spot, 1), 2));
  const auto two = around(h, spot[0], 12);  // …and at scale 2
  for (size_t i = 0; i < one.size(); ++i) {
    CAPTURE(i);
    INFO(one[i] << " vs " << two[i]);
    CHECK(one[i] > 0.05f);
    CHECK(two[i] == doctest::Approx(one[i]).epsilon(0.25));
    CHECK(far[i] < 0.01f);  // 24 pt out it is gone
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

TEST_CASE("meter renderer: the ring is drawn in its own color") {
  Harness h;
  REQUIRE_GPU(h);
  const nmr::Guides guides = nmr::guides(GuideLevel::kOff, {}, true);
  MeterFrame f = h.frame();
  f.guides = &guides;
  f.look.ring = {0.8f, 0, 0, 0.8f};
  REQUIRE(h.render(f));
  const float c = std::cos(0.5f);
  const float s = std::sin(0.5f);
  const Rgb on = h.at({c, s});  // on the unit circle, off every axis
  CHECK(on.r > 0.3f);
  CHECK(on.b < 0.05f);
  CHECK(h.at({0.8f * c, 0.8f * s}).peak() < 0.02f);  // inside it: dark
}

TEST_CASE("meter renderer: whiten turns the hottest light white") {
  Harness h;
  REQUIRE_GPU(h);
  const std::vector<ScopePoint> spot(4, ScopePoint{0.3f, -0.2f});  // bright, not saturated
  const auto core = [&](float whiten) {
    MeterFrame f = spotFrame(h, spot, 0);
    f.look.solid_color = {0x89 / 255.0f, 0x93 / 255.0f, 1.0f};  // iris
    f.look.whiten = whiten;
    REQUIRE(h.render(f));
    const Rgb c = h.at(spot[0]);
    REQUIRE(c.peak() > 0.1f);
    return std::min({c.r, c.g, c.b}) / c.peak();  // 1 is white
  };
  const float none = core(0);
  const float some = core(0.12f);
  const float much = core(0.6f);
  INFO(none << " " << some << " " << much);
  CHECK(none < some);
  CHECK(some < much);
  CHECK(much > 0.85f);
}

TEST_CASE("meter renderer: the glow takes the glow color") {
  Harness h;
  REQUIRE_GPU(h);
  const std::vector<ScopePoint> spot(64, ScopePoint{0.3f, -0.2f});
  const auto white = [&] {  // a white trace, so the halo's tint is the glow color's alone
    MeterFrame f = spotFrame(h, spot, 1);
    f.look.solid = true;
    f.look.solid_color = {1, 1, 1};
    return f;
  };
  const auto halo = [&](std::array<float, 3> color) {
    MeterFrame f = white();
    f.look.glow_color = color;
    REQUIRE(h.render(f));
    return around(h, spot[0], 8)[0];
  };
  REQUIRE(h.render(white()));
  const Rgb neutral = h.pixel(h.place(spot[0])[0] + 8, h.place(spot[0])[1]);
  CHECK(neutral.r == doctest::Approx(neutral.b).epsilon(0.05));  // white by default
  MeterFrame red = white();
  red.look.glow_color = {1, 0, 0};
  REQUIRE(h.render(red));
  const Rgb tinted = h.pixel(h.place(spot[0])[0] + 8, h.place(spot[0])[1]);
  CHECK(tinted.r > 0.03f);
  CHECK(tinted.b < 0.25f * tinted.r);
  CHECK(halo({0, 0, 0}) < 0.01f);  // no color, no glow
}
