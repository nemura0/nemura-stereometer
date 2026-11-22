// The stored settings → what a meter view draws (no GPU needed).
#include <nmr/scene_settings.h>

#include <doctest/doctest.h>

#include <cmath>
#include <utility>
#include <vector>

using nmr::MeterSettings;
using nmr::SceneHost;
using nmr::settings::Id;
using nmr::settings::Settings;

namespace {

const nmr::colormap::Table& defaultTable() {
  static const nmr::colormap::Table table = MeterSettings::defaultColormap();
  return table;
}

MeterSettings app(const Settings& s) {
  return nmr::meterSettings(s, SceneHost::kApp, defaultTable());
}

}  // namespace

TEST_CASE("scene settings: the defaults") {
  const MeterSettings m = app(Settings{});
  CHECK(m.trail_s == doctest::Approx(0.1));
  CHECK(m.glow == 0);
  CHECK(m.brightness == doctest::Approx(1));
  CHECK(m.point_size_pt == doctest::Approx(2));
  CHECK(m.line_thickness_pt == doctest::Approx(1.5));
  CHECK(m.density == 2);
  CHECK(m.draw == nmr::DrawStyle::kDots);
  CHECK(m.shape == nmr::PointShape::kSoft);
  CHECK(m.guides == nmr::GuideLevel::kSubtle);
  CHECK_FALSE(m.ring);
  CHECK_FALSE(m.glow_warning);
  CHECK(m.correlation);
  CHECK(m.balance);
  CHECK_FALSE(m.readouts);
  CHECK(m.frame_rate == nmr::FrameRateChoice::kAuto);
  CHECK(m.analyzer.map.scale == nmr::dsp::Scale::kLinear);
  CHECK_FALSE(m.analyzer.map.half);
  CHECK(m.analyzer.map.orientation == nmr::dsp::Orientation::kMidSide);
  CHECK(m.analyzer.map.gain == doctest::Approx(1));
  CHECK(m.analyzer.map.log_range_db == doctest::Approx(48));
  CHECK(m.analyzer.color == nmr::dsp::ColorMode::kFrequency);
  CHECK(m.analyzer.auto_gain == nmr::dsp::AutoGainMode::kOff);
  CHECK(m.analyzer.integration_s == doctest::Approx(0.3));
  CHECK_FALSE(m.look.solid);
  CHECK(m.look.solid_color[0] == doctest::Approx(0x89 / 255.0));
  CHECK(m.look.solid_color[2] == doctest::Approx(1));
  CHECK(m.look.whiten == doctest::Approx(nmr::kDefaultWhiten));
  CHECK(m.look.background[3] == 0);  // the app's background starts fully transparent
}

TEST_CASE("scene settings: each setting reaches the scene") {
  Settings s;
  s.setNumber(Id::kTrailMs, 300);
  s.setNumber(Id::kIntegrationMs, 1200);
  s.setNumber(Id::kGlow, 70);
  s.setNumber(Id::kBrightness, 150);
  s.setNumber(Id::kPointSize, 3.5);
  s.setNumber(Id::kLineThickness, 2.5);
  s.setNumber(Id::kDensity, 6);
  s.setChoice(Id::kDrawStyle, "lines");
  s.setChoice(Id::kPointShape, "square");
  s.setChoice(Id::kGuides, "full");
  s.setNumber(Id::kCorrelationMeter, 0);
  s.setNumber(Id::kBalanceMeter, 0);
  s.setNumber(Id::kMeterReadouts, 1);
  s.setChoice(Id::kFrameRate, "60");
  s.setNumber(Id::kGainDb, 6);
  s.setNumber(Id::kLogRangeDb, 36);
  s.setChoice(Id::kAutoGain, "fast");
  s.setChoice(Id::kColorMode, "solid");
  s.setNumber(Id::kSolidColor, 0x336699FF);
  const MeterSettings m = app(s);
  CHECK(m.trail_s == doctest::Approx(0.3));
  CHECK(m.analyzer.integration_s == doctest::Approx(1.2));
  CHECK(m.glow == doctest::Approx(0.7));
  CHECK(m.brightness == doctest::Approx(1.5));
  CHECK(m.point_size_pt == doctest::Approx(3.5));
  CHECK(m.line_thickness_pt == doctest::Approx(2.5));
  CHECK(m.density == 6);
  CHECK(m.draw == nmr::DrawStyle::kLines);
  CHECK(m.shape == nmr::PointShape::kSquare);
  CHECK(m.guides == nmr::GuideLevel::kFull);
  CHECK_FALSE(m.correlation);
  CHECK_FALSE(m.balance);
  CHECK(m.readouts);
  CHECK(m.frame_rate == nmr::FrameRateChoice::k60);
  CHECK(m.analyzer.map.gain == doctest::Approx(std::pow(10.0, 6.0 / 20)));
  CHECK(m.analyzer.map.log_range_db == doctest::Approx(36));
  CHECK(m.analyzer.auto_gain == nmr::dsp::AutoGainMode::kFast);
  CHECK(m.analyzer.color == nmr::dsp::ColorMode::kSolid);
  CHECK(m.look.solid);
  CHECK(m.look.solid_color[0] == doctest::Approx(0x33 / 255.0));
  CHECK(m.look.solid_color[1] == doctest::Approx(0x66 / 255.0));
  CHECK(m.look.solid_color[2] == doctest::Approx(0x99 / 255.0));
}

TEST_CASE("scene settings: every choice maps to its own value") {
  const auto each = [](Id id, auto expected, auto get) {
    for (const auto& [key, value] : expected) {
      Settings s;
      REQUIRE(s.setChoice(id, key) == nmr::settings::Change::kSet);
      CAPTURE(key);
      CHECK(get(app(s)) == value);
    }
  };
  using nmr::dsp::AutoGainMode;
  using nmr::dsp::ColorMode;
  using Pair = std::pair<const char*, int>;
  const auto as_int = [](auto e) { return static_cast<int>(e); };
  each(Id::kColorMode,
       std::vector<Pair>{{"frequency", as_int(ColorMode::kFrequency)},
                         {"solid", as_int(ColorMode::kSolid)},
                         {"amplitude", as_int(ColorMode::kAmplitude)},
                         {"mid_side", as_int(ColorMode::kMidSide)}},
       [&](const MeterSettings& m) { return as_int(m.analyzer.color); });
  each(Id::kAutoGain,
       std::vector<Pair>{{"off", as_int(AutoGainMode::kOff)},
                         {"slow", as_int(AutoGainMode::kSlow)},
                         {"fast", as_int(AutoGainMode::kFast)}},
       [&](const MeterSettings& m) { return as_int(m.analyzer.auto_gain); });
  each(Id::kPointShape,
       std::vector<Pair>{{"soft", as_int(nmr::PointShape::kSoft)},
                         {"circle", as_int(nmr::PointShape::kCircle)},
                         {"square", as_int(nmr::PointShape::kSquare)}},
       [&](const MeterSettings& m) { return as_int(m.shape); });
  each(Id::kGuides,
       std::vector<Pair>{{"off", as_int(nmr::GuideLevel::kOff)},
                         {"subtle", as_int(nmr::GuideLevel::kSubtle)},
                         {"full", as_int(nmr::GuideLevel::kFull)}},
       [&](const MeterSettings& m) { return as_int(m.guides); });
  each(Id::kDrawStyle,
       std::vector<Pair>{{"dots", as_int(nmr::DrawStyle::kDots)},
                         {"lines", as_int(nmr::DrawStyle::kLines)}},
       [&](const MeterSettings& m) { return as_int(m.draw); });
  each(Id::kFrameRate,
       std::vector<Pair>{{"auto", as_int(nmr::FrameRateChoice::kAuto)},
                         {"120", as_int(nmr::FrameRateChoice::k120)},
                         {"60", as_int(nmr::FrameRateChoice::k60)},
                         {"30", as_int(nmr::FrameRateChoice::k30)}},
       [&](const MeterSettings& m) { return as_int(m.frame_rate); });
}

TEST_CASE("scene settings: the modes and the orientation") {
  const auto with = [](const char* mode, const char* orientation) {
    Settings s;
    s.setChoice(Id::kMode, mode);
    s.setChoice(Id::kOrientation, orientation);
    return app(s).analyzer.map;
  };
  using nmr::dsp::Orientation;
  using nmr::dsp::Scale;
  CHECK(with("goniometer", "left_right").orientation == Orientation::kLeftRight);
  CHECK(with("goniometer_log", "mid_side").scale == Scale::kLog);
  CHECK_FALSE(with("goniometer_log", "mid_side").half);
  CHECK(with("half", "mid_side").half);
  CHECK(with("half", "mid_side").scale == Scale::kLinear);
  CHECK(with("half_log", "mid_side").scale == Scale::kLog);
  CHECK(with("half", "left_right").orientation == Orientation::kMidSide);  // half views are M/S
  CHECK(with("lissajous", "mid_side").orientation == Orientation::kLeftRight);
  CHECK_FALSE(with("lissajous", "mid_side").half);
}

TEST_CASE("scene settings: the original mode is the NEMURA look") {
  Settings s;
  s.setChoice(Id::kMode, "original");
  s.setChoice(Id::kOrientation, "left_right");
  s.setChoice(Id::kGuides, "full");
  const MeterSettings m = app(s);
  CHECK(m.analyzer.map.scale == nmr::dsp::Scale::kLinear);
  CHECK_FALSE(m.analyzer.map.half);
  CHECK(m.analyzer.map.orientation == nmr::dsp::Orientation::kMidSide);
  CHECK(m.ring);
  CHECK(m.guides == nmr::GuideLevel::kFull);  // the other guides still follow the setting
  CHECK(m.look.whiten == doctest::Approx(nmr::kNemuraWhiten));
  REQUIRE(m.glow_warning);
  CHECK((*m.glow_warning)[0] == doctest::Approx(0xE0 / 255.0));
  CHECK((*m.glow_warning)[1] == doctest::Approx(0x3C / 255.0));
  CHECK((*m.glow_warning)[2] == doctest::Approx(0x60 / 255.0));
  CHECK(m.look.glow_color[0] == doctest::Approx(m.look.solid_color[0]));  // the glow starts
  CHECK(m.look.glow_color[2] == doctest::Approx(m.look.solid_color[2]));  // in the trace's color
}

TEST_CASE("scene settings: the background, transparent in the app, never in a plugin") {
  Settings s;
  s.setNumber(Id::kBackgroundColor, 0x204060FF);
  s.setNumber(Id::kBackgroundOpacity, 50);
  const nmr::Premultiplied in_app = app(s).look.background;
  CHECK(in_app[3] == doctest::Approx(0.5));
  CHECK(in_app[0] == doctest::Approx(0x20 / 255.0 * 0.5));
  CHECK(in_app[2] == doctest::Approx(0x60 / 255.0 * 0.5));
  s.setNumber(Id::kBackgroundOpacity, 0);
  const nmr::Premultiplied in_plugin =
      nmr::meterSettings(s, SceneHost::kPlugin, defaultTable()).look.background;
  CHECK(in_plugin[3] == doctest::Approx(1));
  CHECK(in_plugin[1] == doctest::Approx(0x40 / 255.0));
}

TEST_CASE("scene settings: the colormap is the one given") {
  const nmr::colormap::Builtin* chrome = nmr::colormap::findBuiltin("chrome");
  REQUIRE(chrome != nullptr);
  const nmr::colormap::Table table = nmr::colormap::table(chrome->stops);
  CHECK(nmr::meterSettings(Settings{}, SceneHost::kApp, table).colormap == table);
}
