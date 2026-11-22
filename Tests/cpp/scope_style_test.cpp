#include <nmr/scope_style.h>

#include <doctest/doctest.h>

#include <cmath>

using nmr::DrawStyle;
using nmr::ScopeExposure;
using nmr::ScopeStyle;
using nmr::scopeStyle;
using nmr::ScopeStyleInput;

namespace {

// The light a steady sound builds up: what one frame adds, kept over all frames.
double steady(const ScopeStyleInput& input) {
  const ScopeStyle style = scopeStyle(input);
  const double points = input.sample_rate * input.dt * style.density;
  return style.intensity * points / (1 - style.decay);
}

}  // namespace

TEST_CASE("scope style: the trail decays by exp(-dt / trail)") {
  CHECK(scopeStyle({.dt = 1.0 / 120, .trail_s = 0.1}).decay ==
        doctest::Approx(std::exp(-1.0 / 12)));
  CHECK(scopeStyle({.dt = 1.0 / 60, .trail_s = 0.015}).decay ==
        doctest::Approx(std::exp(-1.0 / 0.9)));
  CHECK(scopeStyle({.dt = 0.5, .trail_s = 1}).decay ==
        doctest::Approx(std::exp(-ScopeExposure::kMaxDtS)));
  CHECK(scopeStyle({.dt = 1.0 / 120, .trail_s = 0}).decay ==
        doctest::Approx(std::exp(-(1.0 / 120) / ScopeExposure::kMinTrailS)));
}

TEST_CASE("scope style: a steady sound builds the same image at any rate and trail") {
  for (double fps : {30.0, 60.0, 120.0}) {
    for (double rate : {44100.0, 48000.0, 96000.0}) {
      for (double trail : {0.005, 0.015, 0.1, 1.0, 2.0}) {
        for (uint32_t density : {1u, 2u, 8u}) {
          CAPTURE(fps);
          CAPTURE(rate);
          CAPTURE(trail);
          CAPTURE(density);
          const ScopeStyleInput input{.dt = 1 / fps, .sample_rate = rate, .trail_s = trail,
                                      .brightness = 1.5f, .density = density};
          // Tight: the renderer's float decay must build this image, not a nearby one.
          CHECK(steady(input) ==
                doctest::Approx(1.5 * ScopeExposure::kDots * std::sqrt(density)).epsilon(1e-6));
        }
      }
    }
  }
  ScopeStyleInput lines{.trail_s = 0.3, .style = DrawStyle::kLines};
  CHECK(steady(lines) == doctest::Approx(ScopeExposure::kLines));
  lines.density = 4;
  CHECK(steady(lines) == doctest::Approx(ScopeExposure::kLines * 2));
}

TEST_CASE("scope style: sizes in pixels, at least one") {
  const ScopeStyle dots = scopeStyle({.point_size_pt = 2.5f, .scale = 2});
  CHECK(dots.size_px == doctest::Approx(5));
  const ScopeStyle lines =
      scopeStyle({.line_thickness_pt = 1.5f, .scale = 2, .style = DrawStyle::kLines});
  CHECK(lines.size_px == doctest::Approx(3));
  CHECK(scopeStyle({.point_size_pt = 0.2f, .scale = 1}).size_px == 1);
  CHECK(scopeStyle({.point_size_pt = 2, .scale = NAN}).size_px == doctest::Approx(2));
  CHECK(scopeStyle({.point_size_pt = 2, .scale = 0}).size_px == doctest::Approx(2));
}

TEST_CASE("scope style: density is 1 to 8") {
  CHECK(scopeStyle({.density = 0}).density == 1);
  CHECK(scopeStyle({.density = 5}).density == 5);
  CHECK(scopeStyle({.density = 99}).density == 8);
}

TEST_CASE("scope style: no time, no new light and nothing fades") {
  for (double dt : {0.0, -1.0, std::nan("")}) {
    const ScopeStyle style = scopeStyle({.dt = dt});
    CHECK(style.decay == 1);
    CHECK(style.intensity == 0);
  }
}

TEST_CASE("scope style: a stalled frame is lit as one of the longest") {
  const ScopeStyle longest = scopeStyle({.dt = ScopeExposure::kMaxDtS, .trail_s = 1});
  for (double dt : {0.5, 3.0, double{INFINITY}}) {
    const ScopeStyle style = scopeStyle({.dt = dt, .trail_s = 1});
    CHECK(style.decay == longest.decay);
    CHECK(style.intensity == longest.intensity);
  }
}

TEST_CASE("scope style: inputs out of range are held to it") {
  const ScopeStyle plain = scopeStyle({});
  CHECK(scopeStyle({.sample_rate = 1e9}).intensity ==
        doctest::Approx(scopeStyle({.sample_rate = 768000}).intensity));
  CHECK(scopeStyle({.sample_rate = 100}).intensity ==
        doctest::Approx(scopeStyle({.sample_rate = 8000}).intensity));
  CHECK(scopeStyle({.trail_s = INFINITY}).decay ==
        doctest::Approx(std::exp(-(1.0 / 120) / ScopeExposure::kMaxTrailS)));
  CHECK(scopeStyle({.brightness = INFINITY}).intensity ==
        doctest::Approx(plain.intensity * ScopeExposure::kMaxBrightness));
  CHECK(scopeStyle({.point_size_pt = INFINITY}).size_px == ScopeExposure::kMaxSizePx);
  CHECK(scopeStyle({.point_size_pt = 1e30f, .scale = 1e30f}).size_px == ScopeExposure::kMaxSizePx);
  CHECK(scopeStyle({.point_size_pt = NAN}).size_px == ScopeExposure::kMinSizePx);
}

TEST_CASE("scope style: inputs that are not numbers fall back to the defaults") {
  const ScopeStyle plain = scopeStyle({});
  CHECK(scopeStyle({.brightness = NAN}).intensity == plain.intensity);
  CHECK(scopeStyle({.sample_rate = NAN}).intensity == plain.intensity);
  CHECK(scopeStyle({.sample_rate = 0}).intensity == plain.intensity);
  const ScopeStyle no_trail = scopeStyle({.trail_s = NAN});
  CHECK(no_trail.decay == scopeStyle({.trail_s = ScopeExposure::kMinTrailS}).decay);
  CHECK(std::isfinite(no_trail.intensity));
  CHECK(no_trail.intensity > 0);
  CHECK(scopeStyle({.brightness = -1}).intensity == 0);
}
