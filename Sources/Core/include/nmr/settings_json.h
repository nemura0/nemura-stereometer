// Settings as versioned JSON: the plugin's state (every entry) and presets (the preset entries
// and a name). Documents are untrusted: decoding never throws and never stops half-way. Missing
// entries get their defaults, unknown keys are ignored, values of the wrong type fall back to the
// default, numbers are clamped, and the report counts each case.
//
//   {"version": 1, "name": "Mix", "settings": {"mode": "goniometer", "gain_db": 0, ...}}
#pragma once

#include <nmr/settings.h>

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace nmr::settings {

inline constexpr int kFormatVersion = 1;
inline constexpr size_t kMaxDocumentBytes = 256 * 1024;
inline constexpr size_t kMaxPresetNameBytes = 100;  // UTF-8

enum class Status : uint8_t {
  kOk,
  kNotJson,      // not JSON (a number beyond double range counts: the parser refuses it)
  kNotSettings,  // JSON, but no positive integer "version" and "settings" object
  kTooLarge,     // over kMaxDocumentBytes
  kUnreadable,   // a file that could not be read
};

struct Report {
  Status status = Status::kOk;
  int version = 0;       // the document's version
  bool newer = false;    // written by a newer version: loaded as far as this one understands it
  uint32_t ignored = 0;  // keys this document may not set: unknown, or not stored in presets
  uint32_t invalid = 0;  // values of the wrong type or not among the choices: defaults used
  uint32_t adjusted = 0;  // numbers clamped or rounded, or a preset name cleaned
};

[[nodiscard]] std::string encodeState(const Settings& settings);
// Status other than kOk: the defaults.
[[nodiscard]] Settings decodeState(std::string_view json, Report& report);

struct Preset {
  std::string name;  // decoded without control characters, at most kMaxPresetNameBytes
  Settings settings;  // only the preset entries matter
  bool operator==(const Preset&) const = default;
};

[[nodiscard]] std::string encodePreset(const Preset& preset);
[[nodiscard]] std::optional<Preset> decodePreset(std::string_view json, Report& report);
// The preset entries from `preset`, every other entry from `current`.
[[nodiscard]] Settings applyPreset(const Settings& current, const Settings& preset);

}  // namespace nmr::settings
