// GPU tests of how sharp the scope reads: soft dots are beads that end at their edge, density
// adds points only where there is a gap to fill, and the glow's halo never hazes over a dim
// cloud of dots.
#include "meter_harness.h"

using nmr::PointShape;

namespace {

// Pixels per scope unit along x, from where the renderer lands two points.
float pixelsPerUnit(const Harness& h) {
  return (h.place({0.1f, 0})[0] - h.place({0, 0})[0]) / 0.1f;
}

}  // namespace

TEST_CASE("meter sharpness: a big soft dot is a bead, brightest at its center, dark past it") {
  Harness h;
  REQUIRE_GPU(h);
  const float row = std::round(h.scope().y + h.scope().height / 2);
  const std::vector<ScopePoint> dot{{0, h.scopeY(row + 0.5f)}};
  MeterFrame f = h.frame();
  f.points = dot;
  f.style.size_px = 24;  // radius 12
  f.style.intensity = 0.1f;
  f.clear = true;
  REQUIRE(h.render(f, 2));
  const float x = h.place(dot[0])[0];
  const float center = h.pixel(x, row).peak();
  INFO("center " << center << ", half radius " << h.pixel(x + 6, row).peak() << ", near the edge "
                 << h.pixel(x + 10, row).peak() << ", past it " << h.pixel(x + 13, row).peak());
  CHECK(center > 0.2f);
  CHECK(center > 1.3f * h.pixel(x + 6, row).peak());  // a bright core, not a flat disc…
  CHECK(h.pixel(x + 6, row).peak() > 1.5f * h.pixel(x + 10, row).peak());
  CHECK(h.pixel(x + 10, row).peak() > 0.01f);  // …falling off to its edge…
  CHECK(h.pixel(x + 13, row).peak() < 0.004f);  // …and nothing past it
}

TEST_CASE("meter sharpness: a soft dot carries the light of a circle of its size") {
  Harness h;
  REQUIRE_GPU(h);
  const float row = std::round(h.scope().y + h.scope().height / 2);
  const std::vector<ScopePoint> dot{{0, h.scopeY(row + 0.5f)}};
  MeterFrame f = h.frame();
  f.points = dot;
  f.style.size_px = 24;
  f.style.intensity = 0.2f;
  f.look.whiten = 0;  // so each channel is 1 − exp(−light × gain), and the light comes back
  f.clear = true;
  const float x = h.place(dot[0])[0];
  const auto total = [&](PointShape shape) {
    f.shape = shape;
    REQUIRE(h.render(f));
    float sum = 0;
    for (float dy = -15; dy <= 15; ++dy) {
      for (float dx = -15; dx <= 15; ++dx) {
        const float shown = std::min(h.pixel(x + dx, row + dy).peak(), 0.999f);
        sum += -std::log(1 - shown) / MeterRenderer::kToneGain;
      }
    }
    return sum;
  };
  const float circle = total(PointShape::kCircle);
  const float soft = total(PointShape::kSoft);
  INFO("soft " << soft << ", circle " << circle);
  CHECK(circle > 0);
  CHECK(soft == doctest::Approx(circle).epsilon(0.05));
}

TEST_CASE("meter sharpness: the smallest soft dot lights a pixel wherever it lands") {
  Harness h;
  REQUIRE_GPU(h);
  const float row = std::round(h.scope().y + h.scope().height / 2);
  const float px = pixelsPerUnit(h);
  MeterFrame f = h.frame();
  f.style.size_px = 1;  // the smallest dot: radius 0.5
  f.style.intensity = 0.4f;
  f.clear = true;
  for (const float offset : {0.0f, 0.25f, 0.5f}) {  // from a pixel's center to its corner
    CAPTURE(offset);
    const std::vector<ScopePoint> dot{{offset / px, h.scopeY(row + 0.5f + offset)}};
    f.points = dot;
    REQUIRE(h.render(f));
    const auto [x, y] = h.place(dot[0]);
    float brightest = 0;
    for (float dy = -1; dy <= 1; ++dy) {
      for (float dx = -1; dx <= 1; ++dx) {
        brightest = std::max(brightest, h.pixel(x + dx, y + dy).peak());
      }
    }
    CHECK(brightest > 0.05f);
  }
}

TEST_CASE("meter sharpness: density adds no points between samples closer than a dot") {
  Harness h;
  REQUIRE_GPU(h);
  const float row = std::round(h.scope().y + h.scope().height / 2);
  const float y = h.scopeY(row + 0.5f);
  const float step = 2 / pixelsPerUnit(h);  // 2 px apart, inside an 8 px dot
  const std::vector<ScopePoint> close{{0, y}, {step, y}};
  MeterFrame f = h.frame();
  f.points = close;
  f.style.size_px = 8;
  f.clear = true;
  const float x = h.place(close[1])[0];
  const auto measure = [&](uint32_t density, float intensity) {
    f.style.density = density;
    f.style.intensity = intensity;
    REQUIRE(h.render(f));
    return std::array<float, 3>{h.pixel(x - 6, row).peak(), h.pixel(x, row).peak(),
                                h.pixel(x + 4, row).peak()};
  };
  // Density 8 gives each point an eighth of its sample's light: drawn as one dot per sample,
  // the image is the one density 1 draws, not a smear of eight dimmer dots.
  const auto one = measure(1, 0.4f);
  const auto dense = measure(8, 0.05f);
  for (size_t i = 0; i < one.size(); ++i) {
    CAPTURE(i);
    INFO(dense[i] << " vs " << one[i]);
    CHECK(dense[i] == doctest::Approx(one[i]).epsilon(0.03));
  }
}

TEST_CASE("meter sharpness: density still fills a gap wider than a dot, with the same light") {
  Harness h;
  REQUIRE_GPU(h);
  const float row = std::round(h.scope().y + h.scope().height / 2);
  const float y = h.scopeY(row + 0.5f);
  const float step = 24 / pixelsPerUnit(h);  // 24 px apart: 8 px dots leave gaps
  const std::vector<ScopePoint> wide{{-step / 2, y}, {step / 2, y}};
  MeterFrame f = h.frame();
  f.points = wide;
  f.style.size_px = 8;
  f.style.density = 4;
  f.style.intensity = 0.1f;
  f.clear = true;
  REQUIRE(h.render(f));
  const float mid = h.place({0, y})[0];
  CHECK(h.pixel(mid, row).peak() > 0.05f);                 // a point halfway, 12 px from both
  CHECK(h.pixel(mid - 6, row).peak() > 0.05f);             // and a quarter of the way
}

TEST_CASE("meter sharpness: the glow's halo stays dim around a dense, dim cloud of dots") {
  Harness h;
  REQUIRE_GPU(h);
  const float row = std::round(h.scope().y + h.scope().height / 2);
  const float y = h.scopeY(row + 0.5f);
  const float step = 8 / pixelsPerUnit(h);  // 4 px dots, 8 px apart: a dense cloud
  std::vector<ScopePoint> cloud;
  for (int i = -8; i <= 8; ++i) {
    for (int j = -8; j <= 8; ++j) cloud.push_back({i * step, y + j * step});
  }
  MeterFrame f = h.frame();
  f.points = cloud;
  f.style.size_px = 4;
  f.style.intensity = 0.15f;  // dim dots
  f.clear = true;
  const float x = h.place({0, y})[0];
  const auto measure = [&](float glow) {
    f.glow = glow;
    REQUIRE(h.render(f));
    return std::array<float, 2>{h.pixel(x, row).peak(), h.pixel(x + 4, row + 4).peak()};
  };
  const auto plain = measure(0);
  const auto glowing = measure(1);
  INFO("dot " << plain[0] << " → " << glowing[0] << ", between " << plain[1] << " → "
              << glowing[1]);
  CHECK(plain[0] > 0.15f);
  CHECK(plain[1] < 0.01f);
  CHECK(glowing[1] < 0.1f * plain[0]);  // dark between the dots: no haze over the cloud
}
