// How one frame of the scope is drawn: the trail's decay, each point's intensity and size.
//
// The scope accumulates light: every frame first multiplies what is there by `decay`, then adds
// the new points. Decay is exp(−dt / τ) with τ the trail time, from the link's real dt. A point's
// intensity is brightness × exposure × (1 − decay) / (sample rate × dt), so a steady sound builds
// the same image whatever the frame rate, the sample rate or the trail time: a longer trail only
// spreads the light along the trace. Density adds interpolated points between samples, each
// sharing its sample's light, with a gentle √density gain so denser traces read a little fuller.
//
// A frame longer than kMaxDtS (a stall) decays and is lit as if it lasted kMaxDtS: the caller
// draws at most sample rate × kMaxDtS samples for it (the playhead draws at most 100 ms). Inputs
// out of range are held to it, and ones that are not numbers fall back to the defaults.
#pragma once

#include <cstdint>

namespace nmr {

enum class DrawStyle : uint8_t { kDots, kLines };  // the draw_style setting's order

struct ScopeStyleInput {
  double dt = 1.0 / 120;      // seconds since the previous frame
  double sample_rate = 48000;
  double trail_s = 0.1;       // τ
  float brightness = 1;       // 1 = 100 %
  float point_size_pt = 2;    // a dot's diameter
  float line_thickness_pt = 1.5;
  uint32_t density = 1;       // points per sample, 1–8
  float scale = 1;            // pixels per point
  DrawStyle style = DrawStyle::kDots;
};

struct ScopeStyle {
  float decay = 0;      // what the trail keeps of the last frame
  float intensity = 0;  // light per drawn point (or line segment)
  float size_px = 1;    // a dot's diameter, or a line's thickness
  uint32_t density = 1;
};

struct ScopeExposure {
  static constexpr float kDots = 400;   // tuned on snapshots (Checkpoint B)
  static constexpr float kLines = 120;
  static constexpr float kMinSizePx = 1;
  static constexpr float kMaxSizePx = 256;
  static constexpr float kMaxBrightness = 10;
  static constexpr double kMinTrailS = 0.001;
  static constexpr double kMaxTrailS = 10;
  static constexpr double kMaxDtS = 0.25;  // a longer frame decays as if it were this long
};

[[nodiscard]] ScopeStyle scopeStyle(const ScopeStyleInput& input) noexcept;

}  // namespace nmr
