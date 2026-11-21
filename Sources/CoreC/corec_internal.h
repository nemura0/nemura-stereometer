// Internals shared by the C API's source files; not part of nmr_corec.h.
#pragma once

#include <nmr/settings.h>
#include <nmr/settings_json.h>
#include <nmr/user_files.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <optional>
#include <string_view>
#include <vector>

#include "nmr_corec.h"

struct nmr_settings {
  nmr::settings::Settings value;
};

struct nmr_file_list {
  std::vector<nmr::UserFile> files;
};

namespace nmr::corec {

// Runs `body`, or gives `fallback` if it throws: nothing may cross the C boundary, and Core throws
// nothing but std::bad_alloc.
template <typename Result, typename Body>
Result guarded(Result fallback, Body&& body) noexcept {
  try {
    return body();
  } catch (...) {
    return fallback;
  }
}

// A malloc'd copy the caller frees with nmr_string_free; NULL when memory runs out.
inline char* duplicate(std::string_view text) noexcept {
  auto* copy = static_cast<char*>(std::malloc(text.size() + 1));
  if (copy == nullptr) return nullptr;
  if (!text.empty()) std::memcpy(copy, text.data(), text.size());
  copy[text.size()] = '\0';
  return copy;
}

// The entry at a schema index, if there is one.
inline std::optional<settings::Id> idAt(uint32_t index) noexcept {
  if (index >= settings::kCount) return std::nullopt;
  return static_cast<settings::Id>(index);
}

inline nmr_json_report toC(const settings::Report& report) noexcept {
  return {
      .status = static_cast<nmr_json_status>(report.status),
      .version = report.version,
      .newer = report.newer,
      .ignored = report.ignored,
      .invalid = report.invalid,
      .adjusted = report.adjusted,
  };
}

// An absolute path from the caller; nothing for NULL, "" or a relative path, which the C API never
// resolves against the working directory. Allocates: call it inside guarded().
inline std::optional<std::filesystem::path> absolutePath(const char* text) {
  if (text == nullptr || text[0] != '/') return std::nullopt;
  return std::filesystem::path(text);
}

inline void setError(int32_t* error, int value) noexcept {
  if (error != nullptr) *error = value;
}

// A handle that owns a copy of `value`; NULL when memory runs out.
inline nmr_settings* adopt(const settings::Settings& value) noexcept {
  return guarded<nmr_settings*>(nullptr, [&] { return new nmr_settings{value}; });
}

}  // namespace nmr::corec
