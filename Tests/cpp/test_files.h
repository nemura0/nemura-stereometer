// Test helpers for code that keeps files: a temporary folder removed afterwards, whole-file I/O.
#pragma once

#include <doctest/doctest.h>
#include <unistd.h>

#include <filesystem>
#include <fstream>
#include <iterator>
#include <random>
#include <string>
#include <string_view>
#include <system_error>

namespace nmr::test {

// A new, empty folder in the temporary directory, removed with its contents afterwards.
class TempFolder {
 public:
  TempFolder() {
    std::random_device random;
    path_ = std::filesystem::temp_directory_path() /
            ("nmr-test-" + std::to_string(getpid()) + "-" + std::to_string(random()));
    std::filesystem::create_directories(path_);
  }
  ~TempFolder() {
    std::error_code ignored;
    std::filesystem::remove_all(path_, ignored);
  }
  TempFolder(const TempFolder&) = delete;
  TempFolder& operator=(const TempFolder&) = delete;

  [[nodiscard]] const std::filesystem::path& path() const { return path_; }

 private:
  std::filesystem::path path_;
};

inline void writeFile(const std::filesystem::path& path, std::string_view text) {
  std::ofstream out(path, std::ios::binary);
  out.write(text.data(), static_cast<std::streamsize>(text.size()));
  out.close();
  REQUIRE_FALSE(out.fail());
}

inline std::string readFile(const std::filesystem::path& path) {
  std::ifstream in(path, std::ios::binary);
  REQUIRE(in.good());
  return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

}  // namespace nmr::test
