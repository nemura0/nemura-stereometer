// The settings schema, validated values, the JSON state and presets, and migration
// (nmr/settings.h, nmr/settings_json.h and the Core-internal Sources/Core/settings_migration.h).
#include <doctest/doctest.h>
#include <nlohmann/json.hpp>
#include <nmr/dsp.h>
#include <nmr/settings.h>
#include <nmr/settings_json.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <random>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "settings_migration.h"

namespace st = nmr::settings;
using nlohmann::json;
using st::Id;

namespace {

constexpr double kNaN = std::numeric_limits<double>::quiet_NaN();

Id idOf(std::string_view key) {
  const std::optional<Id> id = st::find(key);
  REQUIRE_MESSAGE(id.has_value(), std::string(key));
  return *id;
}

const st::Spec& specOf(std::string_view key) { return st::spec(idOf(key)); }

Id idAt(size_t index) { return static_cast<Id>(index); }

std::vector<std::string> choiceKeys(const st::Spec& spec) {
  std::vector<std::string> keys;
  for (const st::Choice& choice : spec.choices) keys.emplace_back(choice.key);
  return keys;
}

bool isIdentifier(std::string_view key, bool may_start_with_digit) {
  if (key.empty()) return false;
  if (!may_start_with_digit && !(key[0] >= 'a' && key[0] <= 'z')) return false;
  return std::all_of(key.begin(), key.end(), [](char c) {
    return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_';
  });
}

bool isWhole(double value) { return std::isfinite(value) && std::floor(value) == value; }

// Valid settings with every entry away from its default where it can be (deterministic).
st::Settings randomSettings(std::mt19937& rng) {
  st::Settings settings;
  for (size_t i = 0; i < st::kCount; ++i) {
    const Id id = idAt(i);
    const st::Spec& spec = st::spec(id);
    st::Change change = st::Change::kSet;
    switch (spec.type) {
      case st::Type::kBool:
        change = settings.setNumber(id, static_cast<double>(rng() % 2));
        break;
      case st::Type::kInt: {
        const auto span = static_cast<uint32_t>(spec.max - spec.min) + 1;
        change = settings.setNumber(id, spec.min + static_cast<double>(rng() % span));
        break;
      }
      case st::Type::kFloat:
        change =
            settings.setNumber(id, std::uniform_real_distribution<double>(spec.min, spec.max)(rng));
        break;
      case st::Type::kChoice:
        change = settings.setNumber(id, static_cast<double>(rng() % spec.choices.size()));
        break;
      case st::Type::kColor:
        change = settings.setNumber(id, static_cast<double>(rng()));
        break;
      case st::Type::kText: {
        static constexpr std::string_view kPieces[] = {"Bus", " 2", " · ", "Drums", "é", "🥁", "x"};
        std::string text;
        const uint32_t pieces = rng() % 6;
        for (uint32_t p = 0; p < pieces; ++p) {
          const std::string_view piece = kPieces[rng() % std::size(kPieces)];
          if (text.size() + piece.size() <= spec.max_length) text += piece;
        }
        change = settings.setText(id, text);
        break;
      }
    }
    REQUIRE(change == st::Change::kSet);
  }
  return settings;
}

std::string stateWith(const json& entries) {
  return json{{"version", st::kFormatVersion}, {"settings", entries}}.dump();
}

void checkClean(const st::Report& report) {
  CHECK(report.status == st::Status::kOk);
  CHECK(report.version == st::kFormatVersion);
  CHECK_FALSE(report.newer);
  CHECK(report.ignored == 0);
  CHECK(report.invalid == 0);
  CHECK(report.adjusted == 0);
}

}  // namespace

// ---- Schema ----------------------------------------------------------------------------------

TEST_CASE("schema: one well-formed entry per id, in id order") {
  const std::span<const st::Spec> entries = st::schema();
  REQUIRE(entries.size() == st::kCount);
  std::set<std::string> keys;
  std::set<st::Group> used_groups;
  for (size_t i = 0; i < entries.size(); ++i) {
    const st::Spec& spec = entries[i];
    CAPTURE(spec.key);
    CHECK(&st::spec(idAt(i)) == &spec);
    CHECK(isIdentifier(spec.key, false));
    CHECK(keys.insert(spec.key).second);
    CHECK(st::find(spec.key) == idAt(i));
    REQUIRE(spec.label != nullptr);
    CHECK(std::string_view(spec.label).size() > 0);
    REQUIRE(spec.unit != nullptr);
    REQUIRE(spec.default_text != nullptr);
    CHECK(static_cast<size_t>(spec.group) < st::kGroupCount);
    used_groups.insert(spec.group);
    CHECK((spec.type == st::Type::kChoice) == !spec.choices.empty());
    if (spec.type != st::Type::kFloat) CHECK(spec.stops.empty());
    switch (spec.type) {
      case st::Type::kBool:
        CHECK((spec.default_value == 0 || spec.default_value == 1));
        break;
      case st::Type::kInt:
        CHECK(isWhole(spec.min));
        CHECK(isWhole(spec.max));
        CHECK(isWhole(spec.default_value));
        CHECK(isWhole(spec.step));
        [[fallthrough]];
      case st::Type::kFloat: {
        CHECK(spec.min < spec.max);
        CHECK(spec.default_value >= spec.min);
        CHECK(spec.default_value <= spec.max);
        CHECK(spec.step > 0);
        std::set<std::string> stop_labels;
        for (const st::Stop& stop : spec.stops) {
          CHECK(std::string_view(stop.label).size() > 0);
          CHECK(stop_labels.insert(stop.label).second);
          CHECK(stop.value >= spec.min);
          CHECK(stop.value <= spec.max);
        }
        break;
      }
      case st::Type::kChoice: {
        CHECK(spec.choices.size() >= 2);
        CHECK(isWhole(spec.default_value));
        CHECK(spec.default_value < static_cast<double>(spec.choices.size()));
        std::set<std::string> choice_keys;
        for (const st::Choice& choice : spec.choices) {
          CHECK(isIdentifier(choice.key, true));
          CHECK(choice_keys.insert(choice.key).second);
          CHECK(std::string_view(choice.label).size() > 0);
        }
        break;
      }
      case st::Type::kColor:
        CHECK(isWhole(spec.default_value));
        CHECK(spec.default_value >= 0);
        CHECK(spec.default_value <= 0xFFFFFFFF);
        break;
      case st::Type::kText:
        CHECK(spec.max_length > 0);
        CHECK(std::string_view(spec.default_text).size() <= spec.max_length);
        break;
    }
  }
  CHECK_FALSE(st::find("no_such_setting").has_value());

  std::set<std::string> group_keys;
  for (size_t g = 0; g < st::kGroupCount; ++g) {
    const st::GroupInfo& info = st::group(static_cast<st::Group>(g));
    CAPTURE(g);
    CHECK(isIdentifier(info.key, false));
    CHECK(group_keys.insert(info.key).second);
    CHECK(std::string_view(info.label).size() > 0);
    CHECK(used_groups.count(static_cast<st::Group>(g)) == 1);  // no empty group
  }
}

TEST_CASE("schema: each id names its entry") {
  const std::pair<Id, std::string_view> expected[] = {
      {Id::kMode, "mode"},
      {Id::kLogRangeDb, "log_range_db"},
      {Id::kOrientation, "orientation"},
      {Id::kDrawStyle, "draw_style"},
      {Id::kGuides, "guides"},
      {Id::kPointSize, "point_size"},
      {Id::kPointShape, "point_shape"},
      {Id::kLineThickness, "line_thickness"},
      {Id::kDensity, "density"},
      {Id::kBrightness, "brightness"},
      {Id::kGlow, "glow"},
      {Id::kTrailMs, "trail_ms"},
      {Id::kIntegrationMs, "integration_ms"},
      {Id::kGainDb, "gain_db"},
      {Id::kAutoGain, "auto_gain"},
      {Id::kColorMode, "color_mode"},
      {Id::kColormap, "colormap"},
      {Id::kSolidColor, "solid_color"},
      {Id::kCorrelationMeter, "correlation_meter"},
      {Id::kBalanceMeter, "balance_meter"},
      {Id::kMeterReadouts, "meter_readouts"},
      {Id::kBackgroundColor, "background_color"},
      {Id::kBackgroundOpacity, "background_opacity"},
      {Id::kAlwaysOnTop, "always_on_top"},
      {Id::kClickThrough, "click_through"},
      {Id::kAllSpaces, "all_spaces"},
      {Id::kHoverControls, "hover_controls"},
      {Id::kDockIcon, "dock_icon"},
      {Id::kFrameRate, "frame_rate"},
      {Id::kSendToApp, "send_to_app"},
      {Id::kSourceName, "source_name"},
  };
  REQUIRE(std::size(expected) == st::kCount);
  for (const auto& [id, key] : expected) CHECK(std::string_view(st::spec(id).key) == key);
}

TEST_CASE("schema: the settings and ranges of the brief") {
  struct Number {
    const char* key;
    st::Type type;
    double min, max, default_value;
  };
  for (const Number& n : {
           Number{"log_range_db", st::Type::kFloat, 24, 72, 48},
           Number{"point_size", st::Type::kFloat, 0.5, 12, 2},
           Number{"line_thickness", st::Type::kFloat, 0.5, 6, 1.5},
           Number{"density", st::Type::kInt, 1, 8, 2},
           Number{"brightness", st::Type::kFloat, 10, 300, 100},
           Number{"glow", st::Type::kFloat, 0, 100, 0},
           Number{"trail_ms", st::Type::kFloat, 5, 2000, 100},
           Number{"integration_ms", st::Type::kFloat, 50, 3000, 300},
           Number{"gain_db", st::Type::kFloat, -24, 36, 0},
           Number{"background_opacity", st::Type::kFloat, 0, 100, 0},
       }) {
    CAPTURE(n.key);
    const st::Spec& spec = specOf(n.key);
    CHECK(spec.type == n.type);
    CHECK(spec.min == n.min);
    CHECK(spec.max == n.max);
    CHECK(spec.default_value == n.default_value);
  }

  struct Choices {
    const char* key;
    std::vector<std::string> keys;
    const char* default_key;
  };
  for (const Choices& c : {
           Choices{"mode",
                   {"goniometer", "goniometer_log", "half", "half_log", "lissajous", "original"},
                   "goniometer"},
           Choices{"orientation", {"mid_side", "left_right"}, "mid_side"},
           Choices{"draw_style", {"dots", "lines"}, "dots"},
           Choices{"guides", {"off", "subtle", "full"}, "subtle"},
           Choices{"point_shape", {"soft", "circle", "square"}, "soft"},
           Choices{"auto_gain", {"off", "slow", "fast"}, "off"},
           Choices{"color_mode", {"frequency", "solid", "amplitude", "mid_side"}, "frequency"},
           Choices{"frame_rate", {"auto", "120", "60", "30"}, "auto"},
       }) {
    CAPTURE(c.key);
    const st::Spec& spec = specOf(c.key);
    CHECK(choiceKeys(spec) == c.keys);
    CHECK(st::Settings().choiceKey(idOf(c.key)) == c.default_key);
  }

  // The response presets of the trail time; Instant is calibrated against the reference.
  const st::Spec& trail = specOf("trail_ms");
  REQUIRE(trail.stops.size() == 5);
  CHECK(std::string_view(trail.stops[0].label) == "Instant");
  CHECK(trail.stops[0].value > 5);
  CHECK(trail.stops[0].value < 30);
  const std::vector<std::pair<std::string, double>> expected = {
      {"Fast", 30}, {"Medium", 100}, {"Slow", 300}, {"Very slow", 1000}};
  for (size_t i = 0; i < expected.size(); ++i) {
    CHECK(trail.stops[i + 1].label == expected[i].first);
    CHECK(trail.stops[i + 1].value == expected[i].second);
  }

  CHECK(specOf("solid_color").default_value == 0x8993FFFF);  // Iris
  CHECK(specOf("colormap").type == st::Type::kText);
  CHECK(std::string_view(specOf("colormap").default_text) == "iris");
  for (const char* key : {"correlation_meter", "balance_meter", "meter_readouts", "always_on_top",
                          "click_through", "all_spaces", "hover_controls", "dock_icon",
                          "send_to_app"}) {
    CAPTURE(key);
    CHECK(specOf(key).type == st::Type::kBool);
  }
  CHECK(specOf("source_name").max_length == 63);  // the registry's name[64]
}

TEST_CASE("schema: ranges and choice orders match the DSP") {
  namespace dsp = nmr::dsp;
  const st::Spec& gain = specOf("gain_db");
  CHECK(gain.min == dsp::kMinGainDb);
  CHECK(gain.max == dsp::kMaxGainDb);
  const st::Spec& range = specOf("log_range_db");
  CHECK(range.min == dsp::kMinLogRangeDb);
  CHECK(range.max == dsp::kMaxLogRangeDb);
  CHECK(range.default_value == dsp::kDefaultLogRangeDb);
  const st::Spec& integration = specOf("integration_ms");
  CHECK(integration.min == doctest::Approx(dsp::kMinIntegrationS * 1000));
  CHECK(integration.max == doctest::Approx(dsp::kMaxIntegrationS * 1000));
  CHECK(integration.default_value == doctest::Approx(dsp::kDefaultIntegrationS * 1000));

  // A choice index converts straight to the DSP's enum.
  CHECK(st::findChoice(Id::kColorMode, "frequency") == uint32_t(dsp::ColorMode::kFrequency));
  CHECK(st::findChoice(Id::kColorMode, "solid") == uint32_t(dsp::ColorMode::kSolid));
  CHECK(st::findChoice(Id::kColorMode, "amplitude") == uint32_t(dsp::ColorMode::kAmplitude));
  CHECK(st::findChoice(Id::kColorMode, "mid_side") == uint32_t(dsp::ColorMode::kMidSide));
  CHECK(st::findChoice(Id::kAutoGain, "off") == uint32_t(dsp::AutoGainMode::kOff));
  CHECK(st::findChoice(Id::kAutoGain, "slow") == uint32_t(dsp::AutoGainMode::kSlow));
  CHECK(st::findChoice(Id::kAutoGain, "fast") == uint32_t(dsp::AutoGainMode::kFast));
  CHECK(st::findChoice(Id::kOrientation, "mid_side") == uint32_t(dsp::Orientation::kMidSide));
  CHECK(st::findChoice(Id::kOrientation, "left_right") == uint32_t(dsp::Orientation::kLeftRight));
  CHECK_FALSE(st::findChoice(Id::kOrientation, "diagonal").has_value());
  CHECK_FALSE(st::findChoice(Id::kGainDb, "off").has_value());
}

TEST_CASE("schema: presets store the look; window behavior and instance settings stay out") {
  const std::set<std::string> not_in_presets = {
      "always_on_top", "click_through", "all_spaces", "hover_controls",
      "dock_icon",     "frame_rate",    "send_to_app", "source_name"};
  const std::set<std::string> app_only = {"background_opacity", "always_on_top", "click_through",
                                          "all_spaces",         "hover_controls", "dock_icon"};
  const std::set<std::string> plugin_only = {"send_to_app", "source_name"};
  for (const std::set<std::string>* keys : {&not_in_presets, &app_only, &plugin_only}) {
    for (const std::string& key : *keys) CHECK_MESSAGE(st::find(key).has_value(), key);
  }
  REQUIRE(st::schema().size() == st::kCount);
  for (const st::Spec& spec : st::schema()) {
    CAPTURE(spec.key);
    CHECK(spec.preset == (not_in_presets.count(spec.key) == 0));
    const st::Scope scope = app_only.count(spec.key) != 0      ? st::Scope::kApp
                            : plugin_only.count(spec.key) != 0 ? st::Scope::kPlugin
                                                               : st::Scope::kShared;
    CHECK(spec.scope == scope);
  }
}

// ---- Values ----------------------------------------------------------------------------------

TEST_CASE("settings start at the schema's defaults") {
  const st::Settings settings;
  for (size_t i = 0; i < st::kCount; ++i) {
    const st::Spec& spec = st::spec(idAt(i));
    CAPTURE(spec.key);
    if (spec.type == st::Type::kText) {
      CHECK(settings.text(idAt(i)) == spec.default_text);
      CHECK(settings.number(idAt(i)) == 0);
    } else {
      CHECK(settings.number(idAt(i)) == spec.default_value);
      CHECK(settings.text(idAt(i)).empty());
    }
  }
  CHECK(settings.color(Id::kSolidColor) == 0x8993FFFFu);
  CHECK(settings.flag(Id::kCorrelationMeter));
}

TEST_CASE("settings: numbers are clamped and rounded; NaN and the wrong type are rejected") {
  st::Settings s;
  CHECK(s.setNumber(Id::kGainDb, 100) == st::Change::kAdjusted);
  CHECK(s.number(Id::kGainDb) == 36);
  CHECK(s.setNumber(Id::kGainDb, -5) == st::Change::kSet);
  CHECK(s.setNumber(Id::kGainDb, kNaN) == st::Change::kRejected);
  CHECK(s.number(Id::kGainDb) == -5);
  CHECK(s.setNumber(Id::kGainDb, -std::numeric_limits<double>::infinity()) ==
        st::Change::kAdjusted);
  CHECK(s.number(Id::kGainDb) == -24);

  CHECK(s.setNumber(Id::kDensity, 3.6) == st::Change::kAdjusted);
  CHECK(s.number(Id::kDensity) == 4);
  CHECK(s.setNumber(Id::kDensity, 3) == st::Change::kSet);
  CHECK(s.setNumber(Id::kDensity, 100) == st::Change::kAdjusted);
  CHECK(s.number(Id::kDensity) == 8);

  CHECK(s.setNumber(Id::kDockIcon, 1) == st::Change::kSet);
  CHECK(s.flag(Id::kDockIcon));
  CHECK(s.setNumber(Id::kDockIcon, 0.5) == st::Change::kRejected);
  CHECK(s.setNumber(Id::kDockIcon, 2) == st::Change::kRejected);
  CHECK(s.flag(Id::kDockIcon));

  CHECK(s.setNumber(Id::kMode, 5) == st::Change::kSet);
  CHECK(s.choiceKey(Id::kMode) == "original");
  CHECK(s.setNumber(Id::kMode, 6) == st::Change::kRejected);
  CHECK(s.setNumber(Id::kMode, -1) == st::Change::kRejected);
  CHECK(s.setNumber(Id::kMode, 1.5) == st::Change::kRejected);
  CHECK(s.choice(Id::kMode) == 5);

  CHECK(s.setNumber(Id::kSolidColor, 0x11223344) == st::Change::kSet);
  CHECK(s.color(Id::kSolidColor) == 0x11223344u);
  CHECK(s.setNumber(Id::kSolidColor, -1) == st::Change::kRejected);
  CHECK(s.setNumber(Id::kSolidColor, 4294967296.0) == st::Change::kRejected);
  CHECK(s.setNumber(Id::kSolidColor, 1.5) == st::Change::kRejected);
  CHECK(s.color(Id::kSolidColor) == 0x11223344u);

  CHECK(s.setNumber(Id::kColormap, 1) == st::Change::kRejected);  // a text entry

  CHECK(s.setNumber(Id::kGlow, -0.0) == st::Change::kSet);  // stored as +0, written as 0
  CHECK_FALSE(std::signbit(s.number(Id::kGlow)));
  CHECK(s.setNumber(Id::kMode, -0.0) == st::Change::kSet);
  CHECK_FALSE(std::signbit(s.number(Id::kMode)));

  s.reset(Id::kGainDb);
  s.reset(Id::kMode);
  CHECK(s.number(Id::kGainDb) == 0);
  CHECK(s.choiceKey(Id::kMode) == "goniometer");
}

TEST_CASE("settings: choices by key; text is valid UTF-8 within its length, without controls") {
  st::Settings s;
  CHECK(s.setChoice(Id::kDrawStyle, "lines") == st::Change::kSet);
  CHECK(s.choiceKey(Id::kDrawStyle) == "lines");
  CHECK(s.setChoice(Id::kDrawStyle, "zigzag") == st::Change::kRejected);
  CHECK(s.choiceKey(Id::kDrawStyle) == "lines");
  CHECK(s.setChoice(Id::kGainDb, "off") == st::Change::kRejected);

  CHECK(s.setText(Id::kColormap, "chrome") == st::Change::kSet);
  CHECK(s.text(Id::kColormap) == "chrome");
  CHECK(s.setText(Id::kSourceName, "Bus 2 · Drums 🥁") == st::Change::kSet);
  CHECK(s.setText(Id::kSourceName, std::string(63, 'a')) == st::Change::kSet);
  CHECK(s.setText(Id::kSourceName, std::string(64, 'a')) == st::Change::kRejected);
  for (const char* bad : {"a\nb", "tab\t", "\x7f", "\xC3", "\xC0\xAF", "\xED\xA0\x80",
                          "\xF4\x90\x80\x80", "\xFF"}) {
    CAPTURE(std::string(bad));
    CHECK(s.setText(Id::kSourceName, bad) == st::Change::kRejected);
  }
  CHECK(s.text(Id::kSourceName) == std::string(63, 'a'));
  CHECK(s.setText(Id::kGainDb, "loud") == st::Change::kRejected);
  CHECK(s.setText(Id::kSourceName, "") == st::Change::kSet);  // empty: the automatic name
}

// ---- JSON state ------------------------------------------------------------------------------

TEST_CASE("state JSON: encoding then decoding gives the same settings") {
  std::mt19937 rng(7);
  for (int round = 0; round < 200; ++round) {
    const st::Settings settings = randomSettings(rng);
    st::Report report;
    const st::Settings decoded = st::decodeState(st::encodeState(settings), report);
    CHECK(decoded == settings);
    checkClean(report);
  }
}

TEST_CASE("state JSON: a versioned document with every entry, in the schema's terms") {
  st::Settings settings;
  REQUIRE(settings.setChoice(Id::kGuides, "full") == st::Change::kSet);
  REQUIRE(settings.setNumber(Id::kSolidColor, 0x0A1B2C3D) == st::Change::kSet);
  const json document = json::parse(st::encodeState(settings));
  CHECK(document.at("version") == st::kFormatVersion);
  const json& entries = document.at("settings");
  REQUIRE(entries.is_object());
  CHECK(entries.size() == st::kCount);
  for (const st::Spec& spec : st::schema()) CHECK(entries.contains(spec.key));
  CHECK(entries.at("guides") == "full");
  CHECK(entries.at("solid_color") == "#0A1B2C3D");
  CHECK(entries.at("dock_icon").is_boolean());
  CHECK(entries.at("density").is_number_integer());
  CHECK(entries.at("gain_db").is_number());
  CHECK(entries.at("colormap") == "iris");
}

TEST_CASE("state JSON: missing entries get their defaults; unknown keys are ignored") {
  st::Report report;
  CHECK(st::decodeState(stateWith(json::object()), report) == st::Settings());
  checkClean(report);

  const st::Settings settings =
      st::decodeState(stateWith({{"gain_db", 3}, {"sparkle", true}, {"Gain_dB", 9}}), report);
  CHECK(settings.number(Id::kGainDb) == 3);
  CHECK(report.status == st::Status::kOk);
  CHECK(report.ignored == 2);
  CHECK(report.invalid == 0);
}

TEST_CASE("state JSON: wrong types and unknown choices fall back; numbers are clamped") {
  st::Report report;
  // Raw text, so the duplicate key reaches the parser.
  const st::Settings settings = st::decodeState(R"({"version": 1, "settings": {
      "gain_db": "loud", "mode": "spiral", "density": true, "dock_icon": 1,
      "solid_color": "#12345", "background_color": "#123456", "colormap": 7,
      "point_size": 100, "density": 2.4, "trail_ms": -3}})",
                                                report);
  CHECK(report.status == st::Status::kOk);
  const st::Settings defaults;
  CHECK(settings.number(Id::kGainDb) == defaults.number(Id::kGainDb));
  CHECK(settings.choice(Id::kMode) == defaults.choice(Id::kMode));
  CHECK(settings.flag(Id::kDockIcon) == defaults.flag(Id::kDockIcon));
  CHECK(settings.color(Id::kSolidColor) == defaults.color(Id::kSolidColor));
  CHECK(settings.color(Id::kBackgroundColor) == 0x123456FFu);  // #RRGGBB: opaque
  CHECK(settings.text(Id::kColormap) == defaults.text(Id::kColormap));
  CHECK(settings.number(Id::kPointSize) == 12);
  CHECK(settings.number(Id::kDensity) == 2);  // the later duplicate wins
  CHECK(settings.number(Id::kTrailMs) == 5);
  CHECK(report.invalid == 5);  // gain_db, mode, dock_icon, solid_color, colormap
  CHECK(report.adjusted == 3);  // point_size, density, trail_ms
}

TEST_CASE("state JSON: documents that are not settings are refused with the defaults") {
  struct Case {
    std::string text;
    st::Status status;
  };
  for (const Case& c : {
           Case{"", st::Status::kNotJson},
           Case{"{\"version\": 1, \"settings\": {", st::Status::kNotJson},
           Case{"not json", st::Status::kNotJson},
           Case{"[]", st::Status::kNotSettings},
           Case{"{}", st::Status::kNotSettings},
           Case{"{\"settings\": {}}", st::Status::kNotSettings},
           Case{"{\"version\": \"1\", \"settings\": {}}", st::Status::kNotSettings},
           Case{"{\"version\": 0, \"settings\": {}}", st::Status::kNotSettings},
           Case{"{\"version\": 1.5, \"settings\": {}}", st::Status::kNotSettings},
           Case{"{\"version\": 1, \"settings\": []}", st::Status::kNotSettings},
           Case{"{\"version\": 1}", st::Status::kNotSettings},
           // The parser refuses numbers beyond double range; the encoder never writes one.
           Case{"{\"version\": 1, \"settings\": {\"gain_db\": 1e999}}", st::Status::kNotJson},
           Case{stateWith({{"name", std::string(st::kMaxDocumentBytes, 'x')}}),
                st::Status::kTooLarge},
       }) {
    CAPTURE(c.text.substr(0, 60));
    st::Report report;
    report.ignored = 99;  // the report is reset
    CHECK(st::decodeState(c.text, report) == st::Settings());
    CHECK(report.status == c.status);
    CHECK(report.ignored == 0);
  }
}

TEST_CASE("state JSON: a newer document loads as far as this version understands it") {
  st::Report report;
  const st::Settings settings = st::decodeState(
      json{{"version", st::kFormatVersion + 1}, {"settings", {{"gain_db", 3}, {"warp", 1}}}}.dump(),
      report);
  CHECK(report.status == st::Status::kOk);
  CHECK(report.newer);
  CHECK(report.version == st::kFormatVersion + 1);
  CHECK(report.ignored == 1);
  CHECK(settings.number(Id::kGainDb) == 3);
}

// ---- Migration -------------------------------------------------------------------------------

namespace {

// A pretend history: version 1 named the trail "trail", in seconds; version 2 renamed it
// "trail_s"; version 3 stores milliseconds under today's key.
void renameTrail(json& settings) {
  if (!settings.contains("trail")) return;
  settings["trail_s"] = settings["trail"];
  settings.erase("trail");
}

void trailToMilliseconds(json& settings) {
  if (!settings.contains("trail_s") || !settings["trail_s"].is_number()) return;
  settings["trail_ms"] = settings["trail_s"].get<double>() * 1000;
  settings.erase("trail_s");
}

constexpr st::Migration kPretendChain[] = {renameTrail, trailToMilliseconds};

}  // namespace

TEST_CASE("migration: an older document is upgraded one version at a time") {
  const auto decode = [](int version, const json& entries, st::Report& report) {
    return st::decodeStateWith(json{{"version", version}, {"settings", entries}}.dump(), report,
                               kPretendChain);
  };
  st::Report report;
  CHECK(decode(1, {{"trail", 0.25}}, report).number(Id::kTrailMs) == 250);
  CHECK(report.version == 1);
  CHECK(report.ignored == 0);
  CHECK_FALSE(report.newer);
  CHECK(decode(2, {{"trail_s", 0.5}}, report).number(Id::kTrailMs) == 500);
  CHECK(decode(3, {{"trail_ms", 40}}, report).number(Id::kTrailMs) == 40);
  CHECK_FALSE(report.newer);
  CHECK(decode(3, {{"trail_s", 0.5}}, report).number(Id::kTrailMs) == 100);  // not migrated
  CHECK(report.ignored == 1);
  CHECK(decode(4, {{"trail_ms", 40}}, report).number(Id::kTrailMs) == 40);
  CHECK(report.newer);
}

TEST_CASE("migration: the production chain leads to kFormatVersion") {
  CHECK(st::kFormatVersion == 1 + static_cast<int>(st::migrations().size()));
  st::Settings settings;
  REQUIRE(settings.setNumber(Id::kGainDb, 6) == st::Change::kSet);
  st::Report report;
  CHECK(st::decodeStateWith(st::encodeState(settings), report, st::migrations()) == settings);
  checkClean(report);
}

// ---- Presets ---------------------------------------------------------------------------------

TEST_CASE("presets: only preset entries are written, and applying one keeps everything else") {
  std::mt19937 rng(11);
  const st::Settings look = randomSettings(rng);
  const st::Preset preset{"Late Night", look};
  const json document = json::parse(st::encodePreset(preset));
  CHECK(document.at("version") == st::kFormatVersion);
  CHECK(document.at("name") == "Late Night");
  size_t preset_entries = 0;
  for (const st::Spec& spec : st::schema()) {
    CAPTURE(spec.key);
    CHECK(document.at("settings").contains(spec.key) == spec.preset);
    preset_entries += spec.preset ? 1 : 0;
  }
  CHECK(document.at("settings").size() == preset_entries);

  st::Report report;
  const std::optional<st::Preset> decoded = st::decodePreset(st::encodePreset(preset), report);
  REQUIRE(decoded.has_value());
  checkClean(report);
  CHECK(decoded->name == "Late Night");

  const st::Settings current = randomSettings(rng);
  const st::Settings applied = st::applyPreset(current, decoded->settings);
  for (size_t i = 0; i < st::kCount; ++i) {
    const st::Spec& spec = st::spec(idAt(i));
    CAPTURE(spec.key);
    const st::Settings& source = spec.preset ? look : current;
    CHECK(applied.number(idAt(i)) == source.number(idAt(i)));
    CHECK(applied.text(idAt(i)) == source.text(idAt(i)));
  }
}

TEST_CASE("presets: a preset cannot set window behavior or instance settings") {
  st::Report report;
  const std::optional<st::Preset> preset = st::decodePreset(
      stateWith({{"dock_icon", true}, {"send_to_app", false}, {"gain_db", 6}}), report);
  REQUIRE(preset.has_value());
  CHECK(report.ignored == 2);
  CHECK(preset->name.empty());  // no name in the document
  st::Settings current;
  REQUIRE(current.setNumber(Id::kDockIcon, 0) == st::Change::kSet);
  const st::Settings applied = st::applyPreset(current, preset->settings);
  CHECK(applied.number(Id::kGainDb) == 6);
  CHECK_FALSE(applied.flag(Id::kDockIcon));
  CHECK(applied.flag(Id::kSendToApp));

  CHECK_FALSE(st::decodePreset("[]", report).has_value());
  CHECK(report.status == st::Status::kNotSettings);

  // A name is text to show: invalid UTF-8 and control characters go, and it is cut to 100 bytes.
  const auto named = [&](const std::string& name) {
    return st::decodePreset(
        json{{"version", 1}, {"name", name}, {"settings", json::object()}}.dump(
            -1, ' ', false, json::error_handler_t::ignore),
        report);
  };
  std::optional<st::Preset> cleaned = named("Late\x01 Night\x7f");
  REQUIRE(cleaned.has_value());
  CHECK(cleaned->name == "Late Night");
  CHECK(report.adjusted == 1);
  cleaned = named(std::string(99, 'a') + "é" + std::string(200, 'b'));
  REQUIRE(cleaned.has_value());
  CHECK(cleaned->name == std::string(99, 'a'));
  CHECK(report.adjusted == 1);
  cleaned = named("Fine");
  REQUIRE(cleaned.has_value());
  CHECK(cleaned->name == "Fine");
  CHECK(report.adjusted == 0);
  CHECK_FALSE(st::decodePreset(json{{"version", 1}, {"name", 5}, {"settings", json::object()}}
                                   .dump(),
                               report)
                  .has_value());
  CHECK(report.status == st::Status::kNotSettings);
}
