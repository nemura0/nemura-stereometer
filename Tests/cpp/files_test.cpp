// The file handling shared by presets and colormaps (Sources/Core/files.h).
#include <doctest/doctest.h>

#include <algorithm>
#include <filesystem>
#include <string>
#include <system_error>
#include <vector>

#include "files.h"
#include "test_files.h"

namespace fs = std::filesystem;
namespace files = nmr::files;
using nmr::test::TempFolder;
using nmr::test::writeFile;

namespace {

std::vector<std::string> namesIn(const fs::path& folder) {
  std::vector<std::string> names;
  for (const fs::directory_entry& entry : fs::directory_iterator(folder)) {
    names.push_back(entry.path().filename().string());
  }
  std::sort(names.begin(), names.end());
  return names;
}

}  // namespace

TEST_CASE("list: the extension matches ignoring case; links to files count, nothing else does") {
  TempFolder temp;
  const fs::path& folder = temp.path();
  for (const char* name : {"Lower.map", "Upper.MAP", "Mixed.Map", "Other.mapx", "Short.ma",
                           "map", ".Hidden.map"}) {
    writeFile(folder / name, "[rgb(1, 2, 3); 0.5]");
  }
  fs::create_directory(folder / "Folder.map");
  fs::create_symlink(folder / "Lower.map", folder / "Link.map");
  fs::create_symlink(folder / "Missing.map", folder / "Dangling.map");
  fs::create_symlink(folder / "Folder.map", folder / "FolderLink.map");

  std::vector<std::string> names;
  for (const nmr::UserFile& file : files::list(folder, ".map")) names.push_back(file.name);
  CHECK(names == std::vector<std::string>{"Link", "Lower", "Mixed", "Upper"});
}

TEST_CASE("write: the name must be a plain file name that leaves room for the temporary file") {
  TempFolder temp;
  const fs::path folder = temp.path() / "Out";
  const fs::path elsewhere = temp.path() / "Elsewhere";
  fs::create_directory(elsewhere);
  std::error_code error;
  const std::string rejected[] = {
      "", ".", "..", "Sub/Name.json", (elsewhere / "Name.json").string(),
      std::string("Na\0me.json", 10),
      std::string(248, 'x'),  // with "." and ".XXXXXX" the temporary name would pass 255 bytes
  };
  for (const std::string& name : rejected) {
    CAPTURE(name);
    CHECK(files::write(folder, name, "{}", error).empty());
    CHECK(error == std::errc::invalid_argument);
  }
  CHECK_FALSE(fs::exists(folder));  // refused before anything was created
  CHECK(fs::is_empty(elsewhere));

  const std::string longest(247, 'x');
  CHECK(files::write(folder, longest, "{}", error) == folder / longest);
  CHECK_FALSE(error);
  CHECK(namesIn(folder) == std::vector<std::string>{longest});
}

TEST_CASE("write: a target that cannot be replaced leaves the folder as it was") {
  TempFolder temp;
  const fs::path& folder = temp.path();
  fs::create_directories(folder / "Taken.json" / "Inside");  // a folder holds the name
  std::error_code error;
  CHECK(files::write(folder, "Taken.json", "{}", error).empty());
  CHECK(error);
  CHECK(namesIn(folder) == std::vector<std::string>{"Taken.json"});  // no temporary file left
  CHECK(fs::is_directory(folder / "Taken.json" / "Inside"));
}
