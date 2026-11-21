#include <nmr/settings_json.h>

#include <nlohmann/json.hpp>

#include <array>
#include <cstdio>
#include <limits>

#include "settings_migration.h"
#include "utf8.h"

namespace nmr::settings {
namespace {

using nlohmann::json;
using nlohmann::ordered_json;

std::string formatColor(uint32_t rgba) {
  char text[10];
  std::snprintf(text, sizeof text, "#%08X", rgba);
  return text;
}

// "#RRGGBBAA", or "#RRGGBB" for an opaque color.
std::optional<uint32_t> parseColor(std::string_view text) {
  if ((text.size() != 7 && text.size() != 9) || text[0] != '#') return std::nullopt;
  uint32_t value = 0;
  for (const char c : text.substr(1)) {
    uint32_t digit = 0;
    if (c >= '0' && c <= '9') {
      digit = static_cast<uint32_t>(c - '0');
    } else if (c >= 'a' && c <= 'f') {
      digit = static_cast<uint32_t>(c - 'a' + 10);
    } else if (c >= 'A' && c <= 'F') {
      digit = static_cast<uint32_t>(c - 'A' + 10);
    } else {
      return std::nullopt;
    }
    value = value << 4 | digit;
  }
  return text.size() == 7 ? (value << 8 | 0xFF) : value;
}

ordered_json encodeValue(const Settings& settings, Id id) {
  switch (spec(id).type) {
    case Type::kBool:
      return settings.flag(id);
    case Type::kInt:
      return static_cast<int64_t>(settings.number(id));
    case Type::kFloat:
      return settings.number(id);
    case Type::kChoice:
      return settings.choiceKey(id);
    case Type::kColor:
      return formatColor(settings.color(id));
    case Type::kText:
      return settings.text(id);
  }
  return nullptr;
}

ordered_json encodeEntries(const Settings& settings, bool presets_only) {
  ordered_json entries = ordered_json::object();
  for (size_t i = 0; i < kCount; ++i) {
    const auto id = static_cast<Id>(i);
    if (presets_only && !spec(id).preset) continue;
    entries[spec(id).key] = encodeValue(settings, id);
  }
  return entries;
}

std::string dump(const ordered_json& document) {
  // Text is valid UTF-8 by construction; replace keeps a bad preset name from throwing.
  return document.dump(2, ' ', false, ordered_json::error_handler_t::replace) + "\n";
}

Change decodeValue(Settings& settings, Id id, const json& value) {
  switch (spec(id).type) {
    case Type::kBool:
      return value.is_boolean() ? settings.setNumber(id, value.get<bool>() ? 1 : 0)
                                : Change::kRejected;
    case Type::kInt:
    case Type::kFloat:
      return value.is_number() ? settings.setNumber(id, value.get<double>()) : Change::kRejected;
    case Type::kChoice:
      return value.is_string() ? settings.setChoice(id, value.get_ref<const std::string&>())
                               : Change::kRejected;
    case Type::kColor: {
      const std::optional<uint32_t> rgba =
          value.is_string() ? parseColor(value.get_ref<const std::string&>()) : std::nullopt;
      return rgba ? settings.setNumber(id, *rgba) : Change::kRejected;
    }
    case Type::kText:
      return value.is_string() ? settings.setText(id, value.get_ref<const std::string&>())
                               : Change::kRejected;
  }
  return Change::kRejected;
}

Settings decodeEntries(const json& entries, bool presets_only, Report& report) {
  Settings settings;
  for (const auto& [key, value] : entries.items()) {
    const std::optional<Id> id = find(key);
    if (!id || (presets_only && !spec(*id).preset)) {
      ++report.ignored;
      continue;
    }
    switch (decodeValue(settings, *id, value)) {
      case Change::kSet:
        break;
      case Change::kAdjusted:
        ++report.adjusted;
        break;
      case Change::kRejected:
        ++report.invalid;
        break;
    }
  }
  return settings;
}

// The document's positive integer version, or 0.
int versionOf(const json& version) {
  constexpr auto kMax = static_cast<uint64_t>(std::numeric_limits<int>::max());
  if (!version.is_number_unsigned()) return 0;  // the parser stores negative numbers as signed
  const uint64_t value = version.get<uint64_t>();
  return value <= kMax ? static_cast<int>(value) : 0;
}

// Parses a document and upgrades its "settings" object to the current version.
Status open(std::string_view text, std::span<const Migration> chain, json& document,
            Report& report) {
  if (text.size() > kMaxDocumentBytes) return Status::kTooLarge;
  document = json::parse(text.begin(), text.end(), nullptr, false);
  if (document.is_discarded()) return Status::kNotJson;
  if (!document.is_object()) return Status::kNotSettings;
  const auto version = document.find("version");
  const auto entries = document.find("settings");
  if (version == document.end() || entries == document.end() || !entries->is_object()) {
    return Status::kNotSettings;
  }
  const int found = versionOf(*version);
  if (found < 1) return Status::kNotSettings;
  const int current = 1 + static_cast<int>(chain.size());
  report.version = found;
  report.newer = found > current;
  for (int step = found; step < current; ++step) chain[static_cast<size_t>(step - 1)](*entries);
  return Status::kOk;
}

}  // namespace

namespace {
constexpr std::array<Migration, 0> kMigrations{};  // add a step for each format change
static_assert(1 + kMigrations.size() == kFormatVersion);
}  // namespace

std::span<const Migration> migrations() noexcept { return kMigrations; }

Settings decodeStateWith(std::string_view text, Report& report, std::span<const Migration> chain) {
  report = Report{};
  json document;
  report.status = open(text, chain, document, report);
  if (report.status != Status::kOk) return Settings();
  return decodeEntries(document["settings"], false, report);
}

std::string encodeState(const Settings& settings) {
  ordered_json document = ordered_json::object();
  document["version"] = kFormatVersion;
  document["settings"] = encodeEntries(settings, false);
  return dump(document);
}

Settings decodeState(std::string_view text, Report& report) {
  return decodeStateWith(text, report, migrations());
}

std::string encodePreset(const Preset& preset) {
  ordered_json document = ordered_json::object();
  document["version"] = kFormatVersion;
  document["name"] = preset.name;
  document["settings"] = encodeEntries(preset.settings, true);
  return dump(document);
}

std::optional<Preset> decodePreset(std::string_view text, Report& report) {
  report = Report{};
  json document;
  report.status = open(text, migrations(), document, report);
  if (report.status != Status::kOk) return std::nullopt;
  std::string name;
  if (const auto found = document.find("name"); found != document.end()) {
    if (!found->is_string()) {
      report = Report{};
      report.status = Status::kNotSettings;
      return std::nullopt;
    }
    const std::string& raw = found->get_ref<const std::string&>();
    name = utf8::clean(raw, kMaxPresetNameBytes);
    if (name != raw) ++report.adjusted;
  }
  return Preset{std::move(name), decodeEntries(document["settings"], true, report)};
}

Settings applyPreset(const Settings& current, const Settings& preset) {
  Settings result = current;
  for (size_t i = 0; i < kCount; ++i) {
    const auto id = static_cast<Id>(i);
    if (!spec(id).preset) continue;
    if (spec(id).type == Type::kText) {
      result.setText(id, preset.text(id));
    } else {
      result.setNumber(id, preset.number(id));
    }
  }
  return result;
}

}  // namespace nmr::settings
