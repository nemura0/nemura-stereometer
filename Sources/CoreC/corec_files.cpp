// The file lists behind nmr_corec.h, for presets and colormaps.
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>

#include "corec_internal.h"
#include "nmr_corec.h"

namespace {

const nmr::UserFile* fileAt(const nmr_file_list* list, uint32_t index) {
  return list != nullptr && index < list->files.size() ? &list->files[index] : nullptr;
}

}  // namespace

uint32_t nmr_file_list_count(const nmr_file_list* list) {
  if (list == nullptr) return 0;
  return static_cast<uint32_t>(
      std::min<size_t>(list->files.size(), std::numeric_limits<uint32_t>::max()));
}

const char* nmr_file_list_name(const nmr_file_list* list, uint32_t index) {
  const nmr::UserFile* file = fileAt(list, index);
  return file != nullptr ? file->name.c_str() : nullptr;
}

const char* nmr_file_list_path(const nmr_file_list* list, uint32_t index) {
  const nmr::UserFile* file = fileAt(list, index);
  return file != nullptr ? file->path.c_str() : nullptr;
}

void nmr_file_list_destroy(nmr_file_list* list) { delete list; }
