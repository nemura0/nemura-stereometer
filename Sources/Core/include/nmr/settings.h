// The settings schema: the single source of truth for every setting (key, type, range, default,
// group, label), shared by the app (through the C API) and the plugin. Settings holds one value
// per entry and validates every change. JSON and presets: nmr/settings_json.h, nmr/presets.h.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>

namespace nmr::settings {

enum class Type : uint8_t { kBool, kInt, kFloat, kChoice, kColor, kText };

// Which product uses an entry.
enum class Scope : uint8_t { kShared, kApp, kPlugin };

enum class Group : uint8_t {
  kDisplay,
  kPoints,
  kResponse,
  kLevel,
  kColor,
  kMeters,
  kWindow,
  kPerformance,
  kPlugin,
  kCount
};
inline constexpr size_t kGroupCount = static_cast<size_t>(Group::kCount);

struct GroupInfo {
  const char* key;
  const char* label;
};

struct Choice {
  const char* key;  // stable JSON value
  const char* label;
};

// A named value of a kFloat entry (the response presets of the trail time).
struct Stop {
  const char* label;
  double value;
};

// All strings are static and NUL-terminated, so the C API hands them out as they are.
struct Spec {
  const char* key;  // stable JSON key, snake_case
  Type type;
  Group group;
  Scope scope;
  bool preset;  // stored in presets; false for app and plugin-instance preferences
  const char* label;
  const char* unit;  // "" when unitless
  double min;        // kInt, kFloat
  double max;
  double step;           // the UI's step (kInt, kFloat)
  double default_value;  // kBool 0/1, kInt, kFloat, kChoice index, kColor 0xRRGGBBAA
  std::span<const Choice> choices;  // kChoice
  std::span<const Stop> stops;      // kFloat
  const char* default_text;         // kText
  uint32_t max_length;              // kText: bytes of UTF-8
};

enum class Id : uint16_t {
  kMode,
  kLogRangeDb,
  kOrientation,
  kDrawStyle,
  kGuides,
  kPointSize,
  kPointShape,
  kLineThickness,
  kDensity,
  kBrightness,
  kGlow,
  kTrailMs,
  kIntegrationMs,
  kGainDb,
  kAutoGain,
  kColorMode,
  kColormap,
  kSolidColor,
  kCorrelationMeter,
  kBalanceMeter,
  kMeterReadouts,
  kBackgroundColor,
  kBackgroundOpacity,
  kAlwaysOnTop,
  kClickThrough,
  kAllSpaces,
  kHoverControls,
  kDockIcon,
  kFrameRate,
  kSendToApp,
  kSourceName,
  kCount
};
inline constexpr size_t kCount = static_cast<size_t>(Id::kCount);

[[nodiscard]] std::span<const Spec> schema() noexcept;  // in Id order
[[nodiscard]] const Spec& spec(Id id) noexcept;
[[nodiscard]] std::optional<Id> find(std::string_view key) noexcept;
[[nodiscard]] const GroupInfo& group(Group group) noexcept;
[[nodiscard]] std::optional<uint32_t> findChoice(Id id, std::string_view key) noexcept;

// What a setter did with a value.
enum class Change : uint8_t {
  kSet,       // taken as given
  kAdjusted,  // clamped into the range or rounded to an integer
  kRejected,  // the wrong type, NaN or not one of the choices: the old value stays
};

class Settings {
 public:
  Settings();  // every entry at its default

  // kBool 0/1, kInt, kFloat, kChoice index, kColor 0xRRGGBBAA; 0 for kText.
  [[nodiscard]] double number(Id id) const noexcept { return numbers_[index(id)]; }
  [[nodiscard]] const std::string& text(Id id) const noexcept { return texts_[index(id)]; }
  [[nodiscard]] bool flag(Id id) const noexcept { return number(id) != 0; }
  [[nodiscard]] uint32_t choice(Id id) const noexcept { return static_cast<uint32_t>(number(id)); }
  [[nodiscard]] std::string_view choiceKey(Id id) const noexcept;
  [[nodiscard]] uint32_t color(Id id) const noexcept { return static_cast<uint32_t>(number(id)); }

  // kBool takes 0 or 1; kInt is rounded; kInt and kFloat are clamped to the range; kChoice takes
  // an index, kColor 0 ... 0xFFFFFFFF.
  Change setNumber(Id id, double value) noexcept;
  Change setChoice(Id id, std::string_view key) noexcept;
  // kText: valid UTF-8 of at most max_length bytes, without control characters.
  Change setText(Id id, std::string_view text);
  void reset(Id id);

  bool operator==(const Settings&) const = default;

 private:
  static constexpr size_t index(Id id) noexcept { return static_cast<size_t>(id); }

  std::array<double, kCount> numbers_{};
  std::array<std::string, kCount> texts_{};
};

}  // namespace nmr::settings
