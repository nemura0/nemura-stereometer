// The factory presets and preset files behind nmr_corec.h.
#include <nmr/presets.h>

#include <cerrno>
#include <filesystem>
#include <memory>
#include <optional>
#include <span>
#include <system_error>
#include <vector>

#include "corec_internal.h"
#include "nmr_corec.h"

namespace fs = std::filesystem;
namespace presets = nmr::presets;
namespace st = nmr::settings;
using nmr::corec::absolutePath;
using nmr::corec::duplicate;
using nmr::corec::guarded;
using nmr::corec::setError;
using nmr::corec::toC;

namespace {

const presets::Preset* factoryAt(uint32_t index) {
  const std::span<const presets::Preset> factory = presets::factory();
  return index < factory.size() ? &factory[index] : nullptr;
}

}  // namespace

uint32_t nmr_presets_factory_count(void) {
  return guarded<uint32_t>(0, [] { return static_cast<uint32_t>(presets::factory().size()); });
}

const char* nmr_presets_factory_name(uint32_t index) {
  return guarded<const char*>(nullptr, [&]() -> const char* {
    const presets::Preset* preset = factoryAt(index);
    return preset != nullptr ? preset->name.c_str() : nullptr;  // static storage
  });
}

nmr_settings* nmr_presets_factory_settings(uint32_t index) {
  return guarded<nmr_settings*>(nullptr, [&]() -> nmr_settings* {
    const presets::Preset* preset = factoryAt(index);
    return preset != nullptr ? new nmr_settings{preset->settings} : nullptr;
  });
}

nmr_settings* nmr_presets_apply(const nmr_settings* current, const nmr_settings* preset) {
  if (current == nullptr || preset == nullptr) return nullptr;
  return guarded<nmr_settings*>(nullptr, [&] {
    return new nmr_settings{st::applyPreset(current->value, preset->value)};
  });
}

char* nmr_presets_directory(void) {
  return guarded<char*>(nullptr, [] { return duplicate(presets::directory().native()); });
}

nmr_file_list* nmr_presets_list(const char* folder) {
  return guarded<nmr_file_list*>(nullptr, [&] {
    const std::optional<fs::path> where = absolutePath(folder);
    return new nmr_file_list{where ? presets::list(*where) : std::vector<nmr::UserFile>{}};
  });
}

nmr_settings* nmr_presets_load(const char* path, char** name, nmr_json_report* report) {
  if (name != nullptr) *name = nullptr;
  // What every early return leaves, a failed allocation included.
  if (report != nullptr) *report = toC(st::Report{.status = st::Status::kUnreadable});
  return guarded<nmr_settings*>(nullptr, [&]() -> nmr_settings* {
    const std::optional<fs::path> file = absolutePath(path);
    if (!file) return nullptr;
    st::Report found;
    std::optional<presets::Preset> preset = presets::load(*file, found);
    if (!preset) {
      if (report != nullptr) *report = toC(found);
      return nullptr;
    }
    std::unique_ptr<nmr_settings> settings(new nmr_settings{std::move(preset->settings)});
    if (name != nullptr) {
      *name = duplicate(preset->name);
      if (*name == nullptr) return nullptr;  // out of memory: `settings` is freed
    }
    if (report != nullptr) *report = toC(found);
    return settings.release();
  });
}

char* nmr_presets_save(const char* folder, const char* name, const nmr_settings* settings,
                       int32_t* error) {
  setError(error, ENOMEM);  // what a failed allocation leaves
  return guarded<char*>(nullptr, [&]() -> char* {
    const std::optional<fs::path> where = absolutePath(folder);
    if (!where || name == nullptr || settings == nullptr) {
      setError(error, EINVAL);
      return nullptr;
    }
    std::error_code failure;
    const fs::path file = presets::save(*where, {name, settings->value}, failure);
    if (file.empty()) {
      setError(error, failure ? failure.value() : EIO);
      return nullptr;
    }
    char* saved = duplicate(file.native());
    if (saved != nullptr) setError(error, 0);
    return saved;
  });
}

bool nmr_presets_remove(const char* path, int32_t* error) {
  setError(error, ENOMEM);
  return guarded(false, [&] {
    const std::optional<fs::path> file = absolutePath(path);
    if (!file) {
      setError(error, EINVAL);
      return false;
    }
    std::error_code failure;
    const bool removed = presets::remove(*file, failure);
    setError(error, removed ? 0 : failure.value());
    return removed;
  });
}

char* nmr_presets_file_name(const char* name) {
  if (name == nullptr) return nullptr;
  return guarded<char*>(nullptr, [&] { return duplicate(presets::fileName(name)); });
}

char* nmr_presets_encode(const char* name, const nmr_settings* settings) {
  if (name == nullptr || settings == nullptr) return nullptr;
  return guarded<char*>(nullptr,
                        [&] { return duplicate(st::encodePreset({name, settings->value})); });
}
