#include <nmr/guides.h>

#include <doctest/doctest.h>

#include <algorithm>
#include <cmath>
#include <utility>
#include <vector>

using nmr::GuideLevel;
using nmr::Guides;
using nmr::GuideSegment;
using nmr::guides;
using nmr::dsp::MapParams;
using nmr::dsp::Orientation;
using nmr::dsp::Point;
using nmr::dsp::Scale;

namespace {

double distanceToSegment(Point p, const GuideSegment& s) {
  const double dx = s.b.x - s.a.x;
  const double dy = s.b.y - s.a.y;
  const double length2 = dx * dx + dy * dy;
  double t = length2 > 0 ? ((p.x - s.a.x) * dx + (p.y - s.a.y) * dy) / length2 : 0;
  t = std::clamp(t, 0.0, 1.0);
  const double ex = s.a.x + t * dx - p.x;
  const double ey = s.a.y + t * dy - p.y;
  return std::sqrt(ex * ex + ey * ey);
}

// Whether the point lies on one of the guides (strong ones only, or any).
bool onGuide(const Guides& g, Point p, bool strong_only, double tolerance = 1e-3) {
  for (uint32_t i = 0; i < g.count; ++i) {
    if (strong_only && !g.segments[i].strong) continue;
    if (distanceToSegment(p, g.segments[i]) <= tolerance) return true;
  }
  return false;
}

uint32_t weakSegments(const Guides& g) {
  uint32_t weak = 0;
  for (uint32_t i = 0; i < g.count; ++i) weak += g.segments[i].strong ? 0 : 1;
  return weak;
}

std::vector<MapParams> allViews() {
  std::vector<MapParams> views;
  for (Scale scale : {Scale::kLinear, Scale::kLog}) {
    for (bool half : {false, true}) {
      for (Orientation o : {Orientation::kMidSide, Orientation::kLeftRight}) {
        if (half && o == Orientation::kLeftRight) continue;  // half views are always M/S
        views.push_back({.scale = scale, .half = half, .orientation = o});
      }
    }
  }
  return views;
}

}  // namespace

TEST_CASE("guides: off draws nothing") {
  for (const MapParams& view : allViews()) CHECK(guides(GuideLevel::kOff, view).count == 0);
}

TEST_CASE("guides: mono, left-only and right-only sound fall on the strong axes") {
  for (const MapParams& view : allViews()) {
    for (GuideLevel level : {GuideLevel::kSubtle, GuideLevel::kFull}) {
      CAPTURE(static_cast<int>(view.scale));
      CAPTURE(view.half);
      CAPTURE(static_cast<int>(view.orientation));
      const Guides g = guides(level, view);
      for (float a : {0.05f, 0.3f, 0.7f, 1.0f}) {
        for (auto [l, r] : {std::pair{a, a}, {-a, -a}, {a, 0.0f}, {0.0f, a}, {-a, 0.0f}}) {
          const Point p = mapPoint(l, r, view);
          if (std::abs(p.x) > 1 || std::abs(p.y) > 1) continue;  // beyond the view
          CHECK(onGuide(g, p, true));
        }
      }
    }
  }
}

TEST_CASE("guides: subtle has no outlines; full adds the side axis and the unit circle") {
  for (const MapParams& view : allViews()) {
    CAPTURE(static_cast<int>(view.scale));
    CAPTURE(view.half);
    CAPTURE(static_cast<int>(view.orientation));
    const Guides subtle = guides(GuideLevel::kSubtle, view);
    for (uint32_t i = 0; i < subtle.count; ++i) CHECK(subtle.segments[i].strong);
    const Guides full = guides(GuideLevel::kFull, view);
    CHECK(full.count > subtle.count);
    // Anti-phase sound lies on the side axis.
    CHECK(onGuide(full, mapPoint(0.5f, -0.5f, view), false));
    // The view's unit circle (the upper half, stretched, in the half modes).
    for (int k = 0; k < 16; ++k) {
      const double angle = (view.half ? M_PI : 2 * M_PI) * (k + 0.5) / 16;
      const auto x = static_cast<float>(std::cos(angle));
      const auto y = static_cast<float>(std::sin(angle));
      CHECK(onGuide(full, view.half ? Point{x, 2 * y - 1} : Point{x, y}, false, 2e-3));
      // In M/S that is full scale: a sample of M/S radius 1 in any direction.
      if (view.orientation == Orientation::kMidSide) {
        CHECK(onGuide(full, mapPoint(y - x, y + x, view), false, 2e-3));
      }
    }
  }
}

TEST_CASE("guides: the log modes ring the dB steps inside the range") {
  for (auto [range, half] : {std::pair{24.0f, false}, {48.0f, false}, {72.0f, false},
                             {24.0f, true}, {48.0f, true}, {72.0f, true}}) {
    CAPTURE(half);
    const MapParams view{.scale = Scale::kLog, .log_range_db = range, .half = half};
    const Guides g = guides(GuideLevel::kFull, view);
    uint32_t rings = 0;
    for (float db : {-6.0f, -12.0f, -24.0f, -48.0f}) {
      CAPTURE(range);
      CAPTURE(db);
      // A sample of M/S radius `level`, 20° off the mono axis (away from every axis).
      const float level = std::pow(10.0f, db / 20);
      const float mid = level * std::cos(0.35f);
      const float side = level * std::sin(0.35f);
      const Point p = mapPoint(mid - side, mid + side, view);
      if (-db < range) CHECK(onGuide(g, p, false, 2e-3));  // (beyond it, p is the center)
      rings += -db < range ? 1 : 0;
    }
    // The outlines: the unit circle and one circle per ring inside the range.
    CHECK(weakSegments(g) == (1 + rings) * Guides::kCircleSegments);
  }
  // The linear modes have no rings: the unit circle is their only outline.
  for (const MapParams& view : allViews()) {
    if (view.scale != Scale::kLinear) continue;
    CHECK(weakSegments(guides(GuideLevel::kFull, view)) == Guides::kCircleSegments);
  }
}

TEST_CASE("guides: nothing is drawn twice") {
  const auto same = [](Point p, Point q) { return p.x == q.x && p.y == q.y; };
  for (const MapParams& view : allViews()) {
    CAPTURE(view.half);
    const Guides g = guides(GuideLevel::kFull, view);
    for (uint32_t i = 0; i < g.count; ++i) {
      for (uint32_t j = i + 1; j < g.count; ++j) {
        const GuideSegment& a = g.segments[i];
        const GuideSegment& b = g.segments[j];
        CHECK_FALSE(((same(a.a, b.a) && same(a.b, b.b)) || (same(a.a, b.b) && same(a.b, b.a))));
      }
    }
  }
}

TEST_CASE("guides: everything stays in the view, whatever the range and gain") {
  for (const MapParams& base : allViews()) {
    for (float range : {24.0f, 40.97f, 48.0f, 72.0f, NAN, 0.0f, -48.0f, INFINITY}) {
      for (float gain : {1.0f, NAN, INFINITY}) {
        MapParams view = base;
        view.log_range_db = range;
        view.gain = gain;
        const Guides g = guides(GuideLevel::kFull, view);
        CHECK(g.count <= Guides::kMaxSegments);
        for (uint32_t i = 0; i < g.count; ++i) {
          for (Point p : {g.segments[i].a, g.segments[i].b}) {
            CHECK(std::abs(p.x) <= 1 + 1e-5);  // also false for NaN
            CHECK(std::abs(p.y) <= 1 + 1e-5);
          }
        }
      }
    }
  }
}

TEST_CASE("guides: a range out of bounds is held to them, as the analyzer holds it") {
  const auto same = [](const Guides& a, const Guides& b) {
    if (a.count != b.count) return false;
    for (uint32_t i = 0; i < a.count; ++i) {
      if (a.segments[i].a.x != b.segments[i].a.x || a.segments[i].b.y != b.segments[i].b.y) {
        return false;
      }
    }
    return true;
  };
  const auto at = [](float range) {
    return guides(GuideLevel::kFull, {.scale = Scale::kLog, .log_range_db = range});
  };
  CHECK(same(at(NAN), at(48)));
  CHECK(same(at(0), at(24)));
  CHECK(same(at(-48), at(24)));
  CHECK(same(at(INFINITY), at(72)));
  CHECK(same(at(500), at(72)));
  // At the range's edge a ring would be a dot at the center: none is drawn.
  CHECK(weakSegments(at(24.0001f)) == weakSegments(at(24)));
}

TEST_CASE("guides: L/R log rings show where they fit the view, once") {
  // Range 72: the view's unit circle is log radius 1/√2; −24 and −48 dB fall inside it.
  const MapParams lr{.scale = Scale::kLog, .log_range_db = 72,
                     .orientation = Orientation::kLeftRight};
  const Guides g = guides(GuideLevel::kFull, lr);
  for (float db : {-24.0f, -48.0f}) {
    const float level = std::pow(10.0f, db / 20);
    const Point p = mapPoint(level * std::cos(0.35f) - level * std::sin(0.35f),
                             level * std::cos(0.35f) + level * std::sin(0.35f), lr);
    CHECK(onGuide(g, p, false, 2e-3));
  }
  CHECK(weakSegments(g) == 3 * Guides::kCircleSegments);
  // Range 40.97: the −12 dB ring would lie on the unit circle; it is left out.
  MapParams close = lr;
  close.log_range_db = 40.97f;
  CHECK(weakSegments(guides(GuideLevel::kFull, close)) == 2 * Guides::kCircleSegments);
}

TEST_CASE("guides: gain does not move them") {
  const MapParams plain{};
  const MapParams loud{.gain = 4};
  const Guides a = guides(GuideLevel::kFull, plain);
  const Guides b = guides(GuideLevel::kFull, loud);
  REQUIRE(a.count == b.count);
  for (uint32_t i = 0; i < a.count; ++i) {
    CHECK(a.segments[i].a.x == b.segments[i].a.x);
    CHECK(a.segments[i].b.y == b.segments[i].b.y);
  }
}
