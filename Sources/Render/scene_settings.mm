#include <nmr/scene_settings.h>

#include <array>
#include <cmath>
#include <cstdint>
#include <string_view>

namespace nmr {

namespace {

using settings::Id;
using settings::Settings;

std::array<float, 3> rgb(uint32_t rgba) noexcept {
  return {((rgba >> 24) & 0xff) / 255.0f, ((rgba >> 16) & 0xff) / 255.0f,
          ((rgba >> 8) & 0xff) / 255.0f};
}

float alpha(uint32_t rgba) noexcept { return (rgba & 0xff) / 255.0f; }

// The mode's view; `original` is the NEMURA look's (linear, full, M/S).
dsp::MapParams map(const Settings& s) noexcept {
  const std::string_view mode = s.choiceKey(Id::kMode);
  dsp::MapParams m;
  m.gain = static_cast<float>(std::pow(10.0, s.number(Id::kGainDb) / 20));
  m.log_range_db = static_cast<float>(s.number(Id::kLogRangeDb));
  m.scale = mode.ends_with("_log") ? dsp::Scale::kLog : dsp::Scale::kLinear;
  m.half = mode.starts_with("half");
  const bool left_right = mode == "lissajous" ||
                          (mode.starts_with("goniometer") && s.choiceKey(Id::kOrientation) ==
                                                                 "left_right");
  m.orientation = left_right ? dsp::Orientation::kLeftRight : dsp::Orientation::kMidSide;
  return m;
}

Premultiplied background(const Settings& s, SceneHost host) noexcept {
  const uint32_t color = s.color(Id::kBackgroundColor);
  const float a = host == SceneHost::kPlugin  // a DAW cannot show what is behind its window
                      ? 1
                      : alpha(color) * static_cast<float>(s.number(Id::kBackgroundOpacity) / 100);
  const std::array<float, 3> c = rgb(color);
  return {c[0] * a, c[1] * a, c[2] * a, a};
}

}  // namespace

MeterSettings meterSettings(const Settings& s, SceneHost host, const colormap::Table& colormap) {
  MeterSettings m;
  m.analyzer.map = map(s);
  m.analyzer.color = static_cast<dsp::ColorMode>(s.choice(Id::kColorMode));
  m.analyzer.auto_gain = static_cast<dsp::AutoGainMode>(s.choice(Id::kAutoGain));
  m.analyzer.integration_s = s.number(Id::kIntegrationMs) / 1000;
  m.trail_s = s.number(Id::kTrailMs) / 1000;
  m.brightness = static_cast<float>(s.number(Id::kBrightness) / 100);
  m.glow = static_cast<float>(s.number(Id::kGlow) / 100);
  m.point_size_pt = static_cast<float>(s.number(Id::kPointSize));
  m.line_thickness_pt = static_cast<float>(s.number(Id::kLineThickness));
  m.density = static_cast<uint32_t>(s.number(Id::kDensity));
  m.draw = static_cast<DrawStyle>(s.choice(Id::kDrawStyle));
  m.shape = static_cast<PointShape>(s.choice(Id::kPointShape));
  m.guides = static_cast<GuideLevel>(s.choice(Id::kGuides));
  m.correlation = s.flag(Id::kCorrelationMeter);
  m.balance = s.flag(Id::kBalanceMeter);
  m.readouts = s.flag(Id::kMeterReadouts);
  m.frame_rate = static_cast<FrameRateChoice>(s.choice(Id::kFrameRate));
  m.look.solid = m.analyzer.color == dsp::ColorMode::kSolid;
  m.look.solid_color = rgb(s.color(Id::kSolidColor));
  m.look.background = background(s, host);
  m.colormap = colormap;
  if (s.choiceKey(Id::kMode) == "original") {
    m.ring = true;
    m.look.whiten = kNemuraWhiten;
    m.look.glow_color = m.look.solid_color;
    m.glow_warning = rgb(kNemuraWarning);
  }
  return m;
}

}  // namespace nmr
