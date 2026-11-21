// Core-internal: the small files Core keeps for the user in Application Support (presets,
// colormaps), shared by the app and the plugin.
#pragma once

#include <nmr/user_files.h>

#include <cstddef>
#include <filesystem>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

namespace nmr::files {

// ~/Library/Application Support/<NMR_SUPPORT_SUBDIR>/<name> in the account's real home (from the
// user database, so also inside a sandboxed host whose HOME is its container; else an absolute
// $HOME). Empty without a home. Nothing is created.
[[nodiscard]] std::filesystem::path supportFolder(std::string_view name);

// The regular files in `folder` (links to them included) ending in `extension` (lowercase, e.g.
// ".map"; matched ignoring ASCII case), hidden files skipped, named by shownName(), sorted by
// name ignoring ASCII case.
[[nodiscard]] std::vector<UserFile> list(const std::filesystem::path& folder,
                                         std::string_view extension);

// A file's shown name: its name without the extension, control characters and invalid UTF-8. Not
// capped: Finder may give a file a longer name than fileName() makes.
[[nodiscard]] std::string shownName(const std::filesystem::path& file);

// A safe file name for `name`: control characters and invalid UTF-8 dropped, '/' and ':' turned
// into '-', no leading dots or spaces and no trailing spaces, at most `max_bytes` without splitting
// a character, `fallback` when nothing is left; then `extension`.
[[nodiscard]] std::string fileName(std::string_view name, size_t max_bytes,
                                   std::string_view fallback, std::string_view extension);

enum class Read { kOk, kUnreadable, kTooLarge };

// All of a regular file of at most `max_bytes`. The file is opened once (O_NONBLOCK) and checked
// through the descriptor, so a FIFO or folder swapped in after a check never blocks or is read.
Read read(const std::filesystem::path& file, size_t max_bytes, std::string& text);

// Writes `text` to `folder`/`name` (the folder created if needed): a hidden temporary file in the
// same folder (mode 0600, flushed to the drive) renamed over the old file, so a failure never
// leaves half a file behind. Returns the file, or an empty path and `error`. `name` is one file
// name as fileName() makes them: not empty, "." or "..", without '/' or NUL, at most NAME_MAX - 8
// bytes (room for the temporary name); anything else fails with invalid_argument before anything
// is created. Blocks until the data reaches the drive (F_FULLFSYNC: up to hundreds of
// milliseconds on an external drive), so callers stay off the main and render threads. The
// rename is not flushed itself: after a power cut the old file may come back, never a broken one.
std::filesystem::path write(const std::filesystem::path& folder, std::string_view name,
                            std::string_view text, std::error_code& error);

// Deletes a file ending in `extension` (lowercase; matched ignoring ASCII case, as list() does).
// Anything else fails with invalid_argument and is left alone; a folder is never deleted.
bool remove(const std::filesystem::path& file, std::string_view extension,
            std::error_code& error);

}  // namespace nmr::files
