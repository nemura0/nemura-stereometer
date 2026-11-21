// Presets: the factory set and the preset files in
// ~/Library/Application Support/<NMR_SUPPORT_SUBDIR>/Presets, shared by the app and the plugin.
// A preset file is named after its preset ("Mix.json"); the file name is the name shown, without
// control characters and invalid UTF-8.
#pragma once

#include <nmr/settings_json.h>
#include <nmr/user_files.h>

#include <filesystem>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

namespace nmr::presets {

using settings::Preset;
using settings::Report;

// Mix, Stage, the original mode's preset (named after the vendor) and Classic.
[[nodiscard]] std::span<const Preset> factory();

// The user's preset folder (the real home, also inside a sandboxed host). Nothing is created.
[[nodiscard]] std::filesystem::path directory();

using Entry = UserFile;

// The *.json files in `folder` (the extension in any case; hidden files and folders skipped),
// named as load() names them, sorted by name, ignoring case.
[[nodiscard]] std::vector<Entry> list(const std::filesystem::path& folder);
// The preset in `file`, named after the file.
[[nodiscard]] std::optional<Preset> load(const std::filesystem::path& file, Report& report);
// Writes `preset` to `folder` (created if needed) under fileName(), replacing a file of that
// name atomically. Returns the file, or an empty path and `error`. Names that differ only in case
// or Unicode normalization share a file on a default APFS volume: ask before replacing one.
// Blocks until the file reaches the drive: call it off the main and render threads.
std::filesystem::path save(const std::filesystem::path& folder, const Preset& preset,
                           std::error_code& error);
// Deletes a preset file (never a folder).
bool remove(const std::filesystem::path& file, std::error_code& error);

// A safe file name for a preset name: no '/', ':' or control characters, no leading dots or
// spaces, at most settings::kMaxPresetNameBytes of UTF-8, "Preset" when nothing is left, plus
// ".json".
[[nodiscard]] std::string fileName(std::string_view name);

}  // namespace nmr::presets
