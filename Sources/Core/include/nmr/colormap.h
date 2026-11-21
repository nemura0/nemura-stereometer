// Colormaps turn a position t in 0…1 into a color: the original set built in here, and colormaps
// imported from a user's MiniMeters `.map` files. A `.map` file lists stops, one per bracket:
// "[rgb(r, g, b); position]" or "[rgba(r, g, b, a); position]", components 0–255, positions
// 0–1, "//" starting a comment. Colors are sRGB with straight alpha, interpolated in sRGB.
#pragma once

#include <nmr/user_files.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

namespace nmr::colormap {

struct Rgba {
  uint8_t r = 0;
  uint8_t g = 0;
  uint8_t b = 0;
  uint8_t a = 255;
  bool operator==(const Rgba&) const = default;
};

struct Stop {
  float position = 0;  // 0…1
  Rgba color;
  bool operator==(const Stop&) const = default;
};

struct Builtin {
  std::string_view key;    // what settings store ("iris")
  std::string_view label;  // what the UI shows ("Iris")
  std::span<const Stop> stops;
};

inline constexpr std::string_view kDefaultKey = "iris";
inline constexpr std::string_view kUserPrefix = "user:";
// A setting key holds "user:" plus the name of any file in the colormap folder (NAME_MAX is 255
// bytes, ".map" included).
inline constexpr size_t kMaxKeyBytes = 256;

// Iris (the default, built on #8993FF), Chrome, Bloodmoon (built on #E03C60), Phosphor, Aurora and
// Glacier. Every one is opaque, runs from 0 to 1 and keeps t = 0 (bass) visible on a dark
// background. Keys and labels are string literals, so data() is NUL-terminated.
[[nodiscard]] std::span<const Builtin> builtins() noexcept;
[[nodiscard]] const Builtin* findBuiltin(std::string_view key) noexcept;

// The color at t, clamped to 0…1 (NaN reads as 0): linear between the stops around t, the first
// stop's color before it and the last's after it. Where stops share a position (a hard edge) the
// later one holds from that position on. `stops` sorted by position; none gives transparent black.
[[nodiscard]] Rgba sample(std::span<const Stop> stops, float t) noexcept;

inline constexpr size_t kTableSize = 256;
using Table = std::array<Rgba, kTableSize>;
// Entry i is sample(stops, i / 255).
[[nodiscard]] Table table(std::span<const Stop> stops) noexcept;

// ---- .map files ------------------------------------------------------------------------------

inline constexpr size_t kMaxMapBytes = 64 * 1024;
inline constexpr size_t kMaxStops = 256;

enum class Status {
  kOk,
  kNoStops,     // nothing but malformed entries
  kTooLarge,    // over kMaxMapBytes
  kUnreadable,  // missing, not a regular file, or unreadable
};

struct Report {
  Status status = Status::kOk;
  uint32_t skipped = 0;   // bracketed entries that are not stops, and stops past kMaxStops
  uint32_t adjusted = 0;  // components above 255 or positions above 1, clamped
};

// The stops in `text`, sorted by position (stably: a hard edge keeps the file's order), decimal
// components rounded. Reads the same under any locale.
[[nodiscard]] std::optional<std::vector<Stop>> parseMap(std::string_view text, Report& report);
// One stop per line, "[rgb(r, g, b); position]" or rgba when not opaque; parseMap() reads it back
// unchanged.
[[nodiscard]] std::string formatMap(std::span<const Stop> stops);

// ---- the user's colormaps: ~/Library/Application Support/<NMR_SUPPORT_SUBDIR>/Colormaps ------

// The user's colormap folder (the real home, also inside a sandboxed host). Nothing is created.
[[nodiscard]] std::filesystem::path directory();
// The *.map files in `folder` (the extension in any case; hidden files and folders skipped),
// sorted by name, ignoring case.
[[nodiscard]] std::vector<UserFile> list(const std::filesystem::path& folder);
[[nodiscard]] std::optional<std::vector<Stop>> load(const std::filesystem::path& file,
                                                    Report& report);
// Reads `source` and, when it holds stops, writes them to `folder` (created if needed) as
// "<the source's name>.map", replacing a colormap of that name. Returns the new file, or an empty
// path when nothing was imported: `report.status` says why when it is not kOk, otherwise `error`
// does (the folder could not be written). Blocks until the file reaches the drive: call it off
// the main and render threads.
std::filesystem::path importMap(const std::filesystem::path& folder,
                                const std::filesystem::path& source, Report& report,
                                std::error_code& error);
// Deletes a colormap file: one ending in .map in any case (anything else fails with
// invalid_argument and is left alone), never a folder.
bool remove(const std::filesystem::path& file, std::error_code& error);

// The setting key of the user colormap listed as `name`.
[[nodiscard]] std::string userKey(std::string_view name);
// The stops a setting key names: a built-in colormap by its key, or "user:<name>" from `folder`.
// A key naming nothing, or a user colormap that does not load, gives Iris and `found` = false.
// A user key lists the folder and reads the file: resolve when the key changes, not per frame.
[[nodiscard]] std::vector<Stop> resolve(std::string_view key, const std::filesystem::path& folder,
                                        bool* found = nullptr);

}  // namespace nmr::colormap
