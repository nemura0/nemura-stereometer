// A file the user keeps in Application Support (a preset or a colormap), as a folder lists it.
#pragma once

#include <filesystem>
#include <string>

namespace nmr {

struct UserFile {
  std::string name;  // shown: the file name without its extension, control characters and bad UTF-8
  std::filesystem::path path;
};

}  // namespace nmr
