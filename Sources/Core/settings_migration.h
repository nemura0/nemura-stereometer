// Core-internal (and tests): the migration chain behind nmr/settings_json.h. Each step upgrades a
// document's "settings" object by one version: step i turns version i + 1 into version i + 2, so
// the current version is 1 + the number of steps.
#pragma once

#include <nmr/settings_json.h>

#include <nlohmann/json.hpp>

#include <span>
#include <string_view>

namespace nmr::settings {

using Migration = void (*)(nlohmann::json& settings);

// The production chain (kFormatVersion == 1 + its size).
[[nodiscard]] std::span<const Migration> migrations() noexcept;

[[nodiscard]] Settings decodeStateWith(std::string_view json, Report& report,
                                       std::span<const Migration> chain);

}  // namespace nmr::settings
