#include <nmr/colormap.h>
#include <nmr/product_config.h>
#include <nmr/settings.h>

#include <algorithm>
#include <cmath>
#include <iterator>

#include "utf8.h"

namespace nmr::settings {
namespace {

constexpr GroupInfo kGroups[] = {
    {"display", "Display"}, {"points", "Points & lines"}, {"response", "Response"},
    {"level", "Level"},     {"color", "Color"},           {"meters", "Meters"},
    {"window", "Window"},   {"performance", "Performance"}, {"plugin", "Plugin"},
};
static_assert(std::size(kGroups) == kGroupCount);

// Choice keys are stored in JSON: never rename one without a migration. The index order of
// orientation, auto_gain and color_mode matches the DSP's enums (nmr/dsp.h).
constexpr Choice kModes[] = {
    {"goniometer", "Goniometer"},
    {"goniometer_log", "Goniometer (Log)"},
    {"half", "Half goniometer"},
    {"half_log", "Half goniometer (Log)"},
    {"lissajous", "Lissajous"},
    {"original", NMR_VENDOR},
};
constexpr Choice kOrientations[] = {{"mid_side", "M/S"}, {"left_right", "L/R"}};
constexpr Choice kDrawStyles[] = {{"dots", "Dots"}, {"lines", "Lines"}};
constexpr Choice kGuides[] = {{"off", "Off"}, {"subtle", "Subtle"}, {"full", "Full"}};
constexpr Choice kPointShapes[] = {{"soft", "Soft"}, {"circle", "Circle"}, {"square", "Square"}};
constexpr Choice kAutoGainModes[] = {{"off", "Off"}, {"slow", "Slow"}, {"fast", "Fast"}};
constexpr Choice kColorModes[] = {
    {"frequency", "Frequency"},
    {"solid", "Solid"},
    {"amplitude", "Amplitude"},
    {"mid_side", "Mid-side"},
};
constexpr Choice kFrameRates[] = {
    {"auto", "Auto"}, {"120", "120 fps"}, {"60", "60 fps"}, {"30", "30 fps"}};

// Instant is calibrated against the reference at Checkpoint B.
constexpr Stop kResponse[] = {
    {"Instant", 15}, {"Fast", 30}, {"Medium", 100}, {"Slow", 300}, {"Very slow", 1000}};

struct Place {
  Group group;
  Scope scope;
  bool preset;
};
constexpr Place in(Group group, Scope scope = Scope::kShared, bool preset = true) {
  return {group, scope, preset};
}

constexpr Spec flag(const char* key, Place place, const char* label, bool value) {
  return {key, Type::kBool, place.group, place.scope, place.preset, label, "", 0, 1, 1,
          value ? 1.0 : 0.0, {}, {}, "", 0};
}

constexpr Spec number(const char* key, Type type, Place place, const char* label,
                      const char* unit, double min, double max, double step, double value,
                      std::span<const Stop> stops = {}) {
  return {key, type, place.group, place.scope, place.preset, label, unit, min, max, step, value,
          {}, stops, "", 0};
}

constexpr Spec choice(const char* key, Place place, const char* label,
                      std::span<const Choice> choices, uint32_t index) {
  return {key, Type::kChoice, place.group, place.scope, place.preset, label, "", 0,
          static_cast<double>(choices.size() - 1), 1, static_cast<double>(index), choices, {},
          "", 0};
}

constexpr Spec color(const char* key, Place place, const char* label, uint32_t rgba) {
  return {key, Type::kColor, place.group, place.scope, place.preset, label, "", 0, 0xFFFFFFFF, 1,
          static_cast<double>(rgba), {}, {}, "", 0};
}

constexpr Spec text(const char* key, Place place, const char* label, const char* value,
                    uint32_t max_length) {
  return {key, Type::kText, place.group, place.scope, place.preset, label, "", 0, 0, 0, 0,
          {}, {}, value, max_length};
}

constexpr uint32_t kMaxNameBytes = 63;  // the transport registry's name[64]
constexpr auto kMaxColormapKeyBytes = static_cast<uint32_t>(colormap::kMaxKeyBytes);
static_assert(colormap::kDefaultKey.data()[colormap::kDefaultKey.size()] == '\0',
              "the schema keeps the default colormap key as a C string");

// In Id order (tested). Keys are stored in JSON: never rename one without a migration.
constexpr Spec kSchema[] = {
    choice("mode", in(Group::kDisplay), "Mode", kModes, 0),
    number("log_range_db", Type::kFloat, in(Group::kDisplay), "Log range", "dB", 24, 72, 1, 48),
    choice("orientation", in(Group::kDisplay), "Orientation", kOrientations, 0),
    choice("draw_style", in(Group::kDisplay), "Draw style", kDrawStyles, 0),
    choice("guides", in(Group::kDisplay), "Guides", kGuides, 1),

    number("point_size", Type::kFloat, in(Group::kPoints), "Point size", "pt", 0.5, 12, 0.1, 2),
    choice("point_shape", in(Group::kPoints), "Point shape", kPointShapes, 0),
    number("line_thickness", Type::kFloat, in(Group::kPoints), "Line thickness", "px", 0.5, 6,
           0.1, 1.5),
    number("density", Type::kInt, in(Group::kPoints), "Density", "×", 1, 8, 1, 2),
    number("brightness", Type::kFloat, in(Group::kPoints), "Brightness", "%", 10, 300, 1, 100),
    number("glow", Type::kFloat, in(Group::kPoints), "Glow", "%", 0, 100, 1, 0),

    number("trail_ms", Type::kFloat, in(Group::kResponse), "Trail", "ms", 5, 2000, 1, 100,
           kResponse),
    number("integration_ms", Type::kFloat, in(Group::kResponse), "Meter integration", "ms", 50,
           3000, 10, 300),

    number("gain_db", Type::kFloat, in(Group::kLevel), "Gain", "dB", -24, 36, 0.5, 0),
    choice("auto_gain", in(Group::kLevel), "Auto-gain", kAutoGainModes, 0),

    choice("color_mode", in(Group::kColor), "Color mode", kColorModes, 0),
    text("colormap", in(Group::kColor), "Colormap", colormap::kDefaultKey.data(),
         kMaxColormapKeyBytes),
    color("solid_color", in(Group::kColor), "Solid color", 0x8993FFFF),

    flag("correlation_meter", in(Group::kMeters), "Correlation meter", true),
    flag("balance_meter", in(Group::kMeters), "Balance meter", true),
    flag("meter_readouts", in(Group::kMeters), "Numeric readouts", false),

    color("background_color", in(Group::kWindow), "Background color", 0x08080CFF),
    number("background_opacity", Type::kFloat, in(Group::kWindow, Scope::kApp),
           "Background opacity", "%", 0, 100, 1, 0),
    flag("always_on_top", in(Group::kWindow, Scope::kApp, false), "Always on top", true),
    flag("click_through", in(Group::kWindow, Scope::kApp, false), "Click-through", false),
    flag("all_spaces", in(Group::kWindow, Scope::kApp, false), "Visible on all Spaces", true),
    flag("hover_controls", in(Group::kWindow, Scope::kApp, false), "Hover controls", true),
    flag("dock_icon", in(Group::kWindow, Scope::kApp, false), "Dock icon", false),

    choice("frame_rate", in(Group::kPerformance, Scope::kShared, false), "Frame rate",
           kFrameRates, 0),

    flag("send_to_app", in(Group::kPlugin, Scope::kPlugin, false), "Send to app", true),
    text("source_name", in(Group::kPlugin, Scope::kPlugin, false), "Source name", "",
         kMaxNameBytes),
};
static_assert(std::size(kSchema) == kCount);

bool isWhole(double value) { return std::floor(value) == value; }

bool isValidText(std::string_view text, uint32_t max_length) {
  if (text.size() > max_length) return false;
  for (size_t at = 0; at < text.size();) {
    const utf8::Decoded decoded = utf8::decode(text, at);
    if (decoded.length == 0 || utf8::isControl(decoded.code_point)) return false;
    at += decoded.length;
  }
  return true;
}

}  // namespace

std::span<const Spec> schema() noexcept { return kSchema; }

const Spec& spec(Id id) noexcept { return kSchema[static_cast<size_t>(id)]; }

std::optional<Id> find(std::string_view key) noexcept {
  for (size_t i = 0; i < kCount; ++i) {
    if (key == kSchema[i].key) return static_cast<Id>(i);
  }
  return std::nullopt;
}

const GroupInfo& group(Group group) noexcept { return kGroups[static_cast<size_t>(group)]; }

std::optional<uint32_t> findChoice(Id id, std::string_view key) noexcept {
  const std::span<const Choice> choices = spec(id).choices;
  for (size_t i = 0; i < choices.size(); ++i) {
    if (key == choices[i].key) return static_cast<uint32_t>(i);
  }
  return std::nullopt;
}

Settings::Settings() {
  for (size_t i = 0; i < kCount; ++i) {
    if (kSchema[i].type == Type::kText) {
      texts_[i] = kSchema[i].default_text;
    } else {
      numbers_[i] = kSchema[i].default_value;
    }
  }
}

std::string_view Settings::choiceKey(Id id) const noexcept {
  const Spec& entry = spec(id);
  if (entry.type != Type::kChoice) return {};
  return entry.choices[choice(id)].key;
}

Change Settings::setNumber(Id id, double value) noexcept {
  const Spec& entry = spec(id);
  double& stored = numbers_[index(id)];
  if (std::isnan(value)) return Change::kRejected;
  switch (entry.type) {
    case Type::kBool:
      if (value != 0 && value != 1) return Change::kRejected;
      stored = value == 0 ? 0.0 : 1.0;
      return Change::kSet;
    case Type::kChoice:
    case Type::kColor:
      if (value < entry.min || value > entry.max || !isWhole(value)) return Change::kRejected;
      stored = value + 0.0;  // no negative zero
      return Change::kSet;
    case Type::kInt:
    case Type::kFloat: {
      const double rounded = entry.type == Type::kInt ? std::round(value) : value;
      stored = std::clamp(rounded, entry.min, entry.max) + 0.0;  // no negative zero
      return stored == value ? Change::kSet : Change::kAdjusted;
    }
    case Type::kText:
      return Change::kRejected;
  }
  return Change::kRejected;
}

Change Settings::setChoice(Id id, std::string_view key) noexcept {
  const std::optional<uint32_t> index = findChoice(id, key);
  if (!index) return Change::kRejected;
  return setNumber(id, *index);
}

Change Settings::setText(Id id, std::string_view text) {
  const Spec& entry = spec(id);
  if (entry.type != Type::kText || !isValidText(text, entry.max_length)) return Change::kRejected;
  texts_[index(id)] = text;
  return Change::kSet;
}

void Settings::reset(Id id) {
  const Spec& entry = spec(id);
  if (entry.type == Type::kText) {
    texts_[index(id)] = entry.default_text;
  } else {
    numbers_[index(id)] = entry.default_value;
  }
}

}  // namespace nmr::settings
