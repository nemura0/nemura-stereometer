#include "files.h"

#include <nmr/product_config.h>

#include <fcntl.h>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstdint>

#include "utf8.h"

namespace nmr::files {
namespace {

namespace fs = std::filesystem;

// write() writes "." + name + kTemporarySuffix, then renames it to the name.
constexpr std::string_view kTemporarySuffix = ".XXXXXX";
constexpr size_t kMaxNameBytes = NAME_MAX - 1 - kTemporarySuffix.size();

// One file name write() accepts: a single path component, with room for its temporary name.
bool isPlainName(std::string_view name) {
  return !name.empty() && name != "." && name != ".." && name.size() <= kMaxNameBytes &&
         name.find_first_of(std::string_view("/\0", 2)) == std::string_view::npos;
}

fs::path home() {
  const long suggested = sysconf(_SC_GETPW_R_SIZE_MAX);
  std::string buffer(suggested > 0 ? static_cast<size_t>(suggested) : 16384, '\0');
  passwd entry{};
  passwd* result = nullptr;
  if (getpwuid_r(getuid(), &entry, buffer.data(), buffer.size(), &result) == 0 &&
      result != nullptr && result->pw_dir != nullptr && result->pw_dir[0] == '/') {
    return result->pw_dir;
  }
  const char* variable = std::getenv("HOME");
  return variable != nullptr && variable[0] == '/' ? fs::path(variable) : fs::path();
}

std::string lowered(std::string_view text) {
  std::string result(text);
  std::transform(result.begin(), result.end(), result.begin(), [](char c) {
    return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c;
  });
  return result;
}

std::error_code lastError() { return {errno, std::generic_category()}; }

Read readOpen(int fd, size_t max_bytes, std::string& text) {
  struct stat info {};
  if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) return Read::kUnreadable;
  if (static_cast<uintmax_t>(info.st_size) > max_bytes) return Read::kTooLarge;
  text.resize(max_bytes + 1);  // a file that grew meanwhile is still caught
  size_t filled = 0;
  while (filled < text.size()) {
    const ssize_t got = ::read(fd, text.data() + filled, text.size() - filled);
    if (got < 0) {
      if (errno == EINTR) continue;
      return Read::kUnreadable;
    }
    if (got == 0) break;
    filled += static_cast<size_t>(got);
  }
  text.resize(filled);
  return filled > max_bytes ? Read::kTooLarge : Read::kOk;
}

std::error_code writeAll(int fd, std::string_view text) {
  while (!text.empty()) {
    const ssize_t written = ::write(fd, text.data(), text.size());
    if (written < 0) {
      if (errno == EINTR) continue;
      return lastError();
    }
    text.remove_prefix(static_cast<size_t>(written));
  }
  return {};
}

}  // namespace

fs::path supportFolder(std::string_view name) {
  const fs::path folder = home();
  if (folder.empty()) return {};
  return folder / "Library" / "Application Support" / NMR_SUPPORT_SUBDIR / name;
}

std::vector<UserFile> list(const fs::path& folder, std::string_view extension) {
  std::vector<UserFile> entries;
  std::error_code error;
  for (fs::directory_iterator it(folder, error), end; !error && it != end; it.increment(error)) {
    const fs::path& path = it->path();
    std::error_code type_error;
    if (path.filename().string().starts_with('.') ||
        lowered(path.extension().string()) != extension || !it->is_regular_file(type_error)) {
      continue;
    }
    entries.push_back({shownName(path), path});
  }
  std::sort(entries.begin(), entries.end(), [](const UserFile& a, const UserFile& b) {
    const std::string la = lowered(a.name);
    const std::string lb = lowered(b.name);
    if (la != lb) return la < lb;
    return a.name != b.name ? a.name < b.name : a.path < b.path;
  });
  return entries;
}

std::string shownName(const fs::path& file) {
  const std::string stem = file.stem().string();
  return utf8::clean(stem, stem.size());
}

std::string fileName(std::string_view name, size_t max_bytes, std::string_view fallback,
                     std::string_view extension) {
  std::string result;
  for (size_t at = 0; at < name.size();) {
    const utf8::Decoded decoded = utf8::decode(name, at);
    if (decoded.length == 0) {  // not UTF-8: dropped
      ++at;
      continue;
    }
    std::string_view piece = name.substr(at, decoded.length);
    at += decoded.length;
    const char32_t c = decoded.code_point;
    if (utf8::isControl(c) || (result.empty() && (c == '.' || c == ' '))) continue;
    if (c == '/' || c == ':') piece = "-";
    if (result.size() + piece.size() > max_bytes) break;
    result += piece;
  }
  while (!result.empty() && result.back() == ' ') result.pop_back();
  if (result.empty()) result = fallback;
  return result += extension;
}

Read read(const fs::path& file, size_t max_bytes, std::string& text) {
  const int fd = ::open(file.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return Read::kUnreadable;
  const Read result = readOpen(fd, max_bytes, text);
  ::close(fd);
  return result;
}

fs::path write(const fs::path& folder, std::string_view name, std::string_view text,
               std::error_code& error) {
  error.clear();
  if (!isPlainName(name)) {
    error = std::make_error_code(std::errc::invalid_argument);
    return {};
  }
  fs::create_directories(folder, error);
  if (error) return {};
  const fs::path file = folder / name;
  // A hidden temporary file in the same folder, renamed over the old file in one step.
  std::string temporary = (folder / ("." + std::string(name).append(kTemporarySuffix))).string();
  const int fd = mkstemp(temporary.data());
  if (fd < 0) {
    error = lastError();
    return {};
  }
  error = writeAll(fd, text);
  // F_FULLFSYNC reaches the drive itself (fsync stops at its cache); file systems without it fall
  // back to fsync. The file keeps the mode mkstemp gives it, 0600.
  if (!error && fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0) error = lastError();
  if (close(fd) != 0 && !error) error = lastError();
  if (!error && std::rename(temporary.c_str(), file.c_str()) != 0) error = lastError();
  if (error) {
    unlink(temporary.c_str());
    return {};
  }
  return file;
}

bool remove(const fs::path& file, std::string_view extension, std::error_code& error) {
  error.clear();
  if (lowered(file.extension().string()) != extension) {
    error = std::make_error_code(std::errc::invalid_argument);
    return false;
  }
  if (::unlink(file.c_str()) != 0) {  // a folder fails (EPERM); fs::remove would delete it
    error = lastError();
    return false;
  }
  return true;
}

}  // namespace nmr::files
