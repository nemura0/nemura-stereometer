#include <nmr/guides.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <numbers>

namespace nmr {

namespace {

using dsp::MapParams;
using dsp::Orientation;
using dsp::Point;

constexpr float kRingsDb[] = {-6, -12, -24, -48};
constexpr float kInView = 1 + 1e-6f;
constexpr float kMinCircle = 0.02f;   // smaller rings would be a dot at the center
constexpr float kSameCircle = 1e-3f;  // circles closer than this (view radius) are drawn once
constexpr uint32_t kMaxCircles = 5;

class Builder {
 public:
  Builder(Guides& guides, const MapParams& params) : guides_(guides), params_(params) {}

  // A ray from the center to where the sample (left, right) at full scale lands, cut at the
  // view's edge. In the half modes the lower half folds onto the upper one: drawn once.
  void axis(float left, float right) {
    if (params_.half && left + right < 0) return;
    const Point center = dsp::mapPoint(0, 0, params_);
    const Point end = dsp::mapPoint(left, right, params_);
    const float dx = end.x - center.x;
    const float dy = end.y - center.y;
    const float t = std::min(reach(center.x, dx), reach(center.y, dy));
    add(center, {center.x + t * dx, center.y + t * dy}, true);
  }

  // A circle of `radius` in the M/S plane after the log mapping (the plane mapPoint starts
  // from); skipped when it does not fit the view, would be a dot, or one already drawn is
  // (nearly) the same.
  void circle(float radius) {
    const bool lr = !params_.half && params_.orientation == Orientation::kLeftRight;
    const float in_view = lr ? radius * std::numbers::sqrt2_v<float> : radius;
    if (!(in_view >= kMinCircle) || in_view > kInView || circles_ == kMaxCircles) return;
    for (uint32_t i = 0; i < circles_; ++i) {
      if (std::abs(drawn_[i] - in_view) < kSameCircle) return;
    }
    drawn_[circles_++] = in_view;
    const double turn = params_.half ? std::numbers::pi : 2 * std::numbers::pi;
    Point previous = place(radius, 0);
    for (uint32_t i = 1; i <= Guides::kCircleSegments; ++i) {
      const Point next = place(radius, turn * i / Guides::kCircleSegments);
      add(previous, next, false);
      previous = next;
    }
  }

 private:
  // A point of the M/S plane (X = side, Y = mid) at `angle` from the side axis, in the view.
  [[nodiscard]] Point place(float radius, double angle) const {
    const auto x = static_cast<float>(radius * std::cos(angle));
    const auto y = static_cast<float>(radius * std::sin(angle));
    if (params_.half) return {x, 2 * y - 1};
    if (params_.orientation == Orientation::kLeftRight) return {y - x, y + x};
    return {x, y};
  }

  // How much of a step `d` from `c` stays within −1 … 1 (at most all of it).
  static float reach(float c, float d) {
    if (c + d > 1) return (1 - c) / d;
    if (c + d < -1) return (-1 - c) / d;
    return 1;
  }

  void add(Point a, Point b, bool strong) {
    if (guides_.count < Guides::kMaxSegments) guides_.segments[guides_.count++] = {a, b, strong};
  }

  Guides& guides_;
  const MapParams& params_;
  std::array<float, kMaxCircles> drawn_{};  // the view radii of the circles drawn
  uint32_t circles_ = 0;
};

}  // namespace

Guides guides(GuideLevel level, const MapParams& params) noexcept {
  Guides result;
  if (level == GuideLevel::kOff) return result;
  MapParams view = params;
  view.gain = 1;
  view.log_range_db = dsp::clampOr(view.log_range_db, dsp::kMinLogRangeDb, dsp::kMaxLogRangeDb,
                                   dsp::kDefaultLogRangeDb);
  Builder build(result, view);
  for (float sign : {1.0f, -1.0f}) {
    build.axis(sign, sign);  // mono
    build.axis(sign, 0);     // left only
    build.axis(0, sign);     // right only
  }
  if (level != GuideLevel::kFull) return result;
  build.axis(1, -1);  // side (anti-phase)
  build.axis(-1, 1);
  // The view's unit circle: in M/S full scale; in L/R the circle through full-scale left and
  // right (linear; in log, a ring at 1/√2 of the log radius).
  const bool lr = !view.half && view.orientation == Orientation::kLeftRight;
  build.circle(lr ? 1 / std::numbers::sqrt2_v<float> : 1.0f);
  if (view.scale == dsp::Scale::kLog) {
    for (float db : kRingsDb) {
      build.circle(1 + db / view.log_range_db);  // = logRadius(level, range), exactly
    }
  }
  return result;
}

}  // namespace nmr
