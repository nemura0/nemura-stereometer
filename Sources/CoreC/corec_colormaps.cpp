// The built-in and user colormaps behind nmr_corec.h.
#include <nmr/colormap.h>

#include <cerrno>
#include <cstddef>
#include <filesystem>
#include <optional>
#include <span>
#include <system_error>
#include <vector>

#include "corec_internal.h"
#include "nmr_corec.h"

namespace fs = std::filesystem;
namespace cm = nmr::colormap;
using nmr::corec::absolutePath;
using nmr::corec::duplicate;
using nmr::corec::guarded;
using nmr::corec::setError;

static_assert(NMR_COLORMAP_TABLE_SIZE == cm::kTableSize);
static_assert(NMR_COLORMAP_OK == static_cast<int>(cm::Status::kOk));
static_assert(NMR_COLORMAP_NO_STOPS == static_cast<int>(cm::Status::kNoStops));
static_assert(NMR_COLORMAP_TOO_LARGE == static_cast<int>(cm::Status::kTooLarge));
static_assert(NMR_COLORMAP_UNREADABLE == static_cast<int>(cm::Status::kUnreadable));

namespace {

nmr_colormap_report toC(const cm::Report& report) noexcept {
  return {
      .status = static_cast<nmr_colormap_status>(report.status),
      .skipped = report.skipped,
      .adjusted = report.adjusted,
  };
}

const cm::Builtin* builtinAt(uint32_t index) noexcept {
  const std::span<const cm::Builtin> builtins = cm::builtins();
  return index < builtins.size() ? &builtins[index] : nullptr;
}

// Why an import wrote nothing, as errno.
int importError(cm::Status status, const std::error_code& failure) noexcept {
  switch (status) {
    case cm::Status::kNoStops:
      return EFTYPE;
    case cm::Status::kTooLarge:
      return EFBIG;
    case cm::Status::kUnreadable:
      return EIO;
    case cm::Status::kOk:  // a colormap, but the folder could not be written
      break;
  }
  return failure ? failure.value() : EIO;
}

void writeTable(const cm::Table& table, uint8_t* rgba) noexcept {
  for (size_t i = 0; i < table.size(); ++i) {
    rgba[4 * i + 0] = table[i].r;
    rgba[4 * i + 1] = table[i].g;
    rgba[4 * i + 2] = table[i].b;
    rgba[4 * i + 3] = table[i].a;
  }
}

}  // namespace

uint32_t nmr_colormaps_builtin_count(void) {
  return static_cast<uint32_t>(cm::builtins().size());
}

const char* nmr_colormaps_builtin_key(uint32_t index) {
  const cm::Builtin* builtin = builtinAt(index);
  return builtin != nullptr ? builtin->key.data() : nullptr;  // a NUL-terminated literal
}

const char* nmr_colormaps_builtin_label(uint32_t index) {
  const cm::Builtin* builtin = builtinAt(index);
  return builtin != nullptr ? builtin->label.data() : nullptr;  // a NUL-terminated literal
}

char* nmr_colormaps_directory(void) {
  return guarded<char*>(nullptr, [] { return duplicate(cm::directory().native()); });
}

nmr_file_list* nmr_colormaps_list(const char* folder) {
  return guarded<nmr_file_list*>(nullptr, [&] {
    const std::optional<fs::path> where = absolutePath(folder);
    return new nmr_file_list{where ? cm::list(*where) : std::vector<nmr::UserFile>{}};
  });
}

char* nmr_colormaps_user_key(const char* name) {
  if (name == nullptr) return nullptr;
  return guarded<char*>(nullptr, [&] { return duplicate(cm::userKey(name)); });
}

bool nmr_colormaps_table(const char* key, const char* folder, uint8_t* rgba) {
  if (rgba == nullptr) return false;
  bool found = false;
  cm::Table table;
  const bool resolved = guarded(false, [&] {
    // A relative folder is refused like a missing one: built-ins only.
    const std::optional<fs::path> where = absolutePath(folder);
    table = cm::table(cm::resolve(key != nullptr ? key : "", where.value_or(fs::path()), &found));
    return true;
  });
  if (!resolved) {  // out of memory: Iris, as for a key that names nothing
    found = false;
    table = cm::table(cm::builtins().front().stops);
  }
  writeTable(table, rgba);
  return found;
}

char* nmr_colormaps_import(const char* folder, const char* source, nmr_colormap_report* report,
                           int32_t* error) {
  // What every early return leaves, a failed allocation included: `error` tells why.
  if (report != nullptr) *report = toC(cm::Report{});
  setError(error, ENOMEM);
  return guarded<char*>(nullptr, [&]() -> char* {
    const std::optional<fs::path> where = absolutePath(folder);
    const std::optional<fs::path> from = absolutePath(source);
    if (!where || !from) {
      setError(error, EINVAL);
      return nullptr;
    }
    cm::Report found;
    std::error_code failure;
    const fs::path file = cm::importMap(*where, *from, found, failure);
    if (report != nullptr) *report = toC(found);
    if (file.empty()) {
      setError(error, importError(found.status, failure));
      return nullptr;
    }
    char* imported = duplicate(file.native());
    if (imported != nullptr) setError(error, 0);
    return imported;
  });
}

bool nmr_colormaps_remove(const char* path, int32_t* error) {
  setError(error, ENOMEM);
  return guarded(false, [&] {
    const std::optional<fs::path> file = absolutePath(path);
    if (!file) {
      setError(error, EINVAL);
      return false;
    }
    std::error_code failure;
    const bool removed = cm::remove(*file, failure);
    setError(error, removed ? 0 : failure.value());
    return removed;
  });
}
