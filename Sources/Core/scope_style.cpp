#include <nmr/scope_style.h>

#include <algorithm>
#include <cmath>

#include <nmr/dsp.h>

namespace nmr {

namespace {

constexpr double kDefaultRate = 48000;  // also for a rate that is not a number
constexpr double kMinRate = 8000;
constexpr double kMaxRate = 768000;
constexpr uint32_t kMaxDensity = 8;

}  // namespace

ScopeStyle scopeStyle(const ScopeStyleInput& input) noexcept {
  ScopeStyle style;
  style.density = std::clamp(input.density, 1u, kMaxDensity);
  const double scale = input.scale > 0 && std::isfinite(input.scale) ? input.scale : 1.0;
  const double size_pt =
      input.style == DrawStyle::kLines ? input.line_thickness_pt : input.point_size_pt;
  // NaN falls to the smallest size; std::clamp would pass it through.
  const double size = size_pt * scale;
  style.size_px = static_cast<float>(
      size >= ScopeExposure::kMinSizePx ? std::min<double>(size, ScopeExposure::kMaxSizePx)
                                        : ScopeExposure::kMinSizePx);

  if (!(input.dt > 0)) {  // no time passed (or none known): keep the image as it is
    style.decay = 1;
    return style;
  }
  const double dt = std::min(input.dt, ScopeExposure::kMaxDtS);
  const double trail = dsp::clampOr(input.trail_s, ScopeExposure::kMinTrailS,
                                    ScopeExposure::kMaxTrailS, ScopeExposure::kMinTrailS);
  const double rate = std::clamp(input.sample_rate > 0 ? input.sample_rate : kDefaultRate,
                                 kMinRate, kMaxRate);
  const double brightness = dsp::clampOr(input.brightness, 0.0f, ScopeExposure::kMaxBrightness, 1.0f);
  style.decay = static_cast<float>(std::exp(-dt / trail));

  const double exposure =
      input.style == DrawStyle::kLines ? ScopeExposure::kLines : ScopeExposure::kDots;
  const double points = rate * dt * style.density;
  // From the decay as stored, so the renderer's float decay builds exactly this image.
  const double kept = 1 - static_cast<double>(style.decay);
  style.intensity = static_cast<float>(brightness * exposure * std::sqrt(style.density) * kept /
                                       points);
  return style;
}

}  // namespace nmr
