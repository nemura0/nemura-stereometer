#include <nmr/presets.h>
#include <nmr/product_config.h>

#include <fcntl.h>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>

#include "utf8.h"

namespace nmr::presets {
namespace {

namespace fs = std::filesystem;
using settings::Id;
using settings::Settings;
using settings::Status;

double response(std::string_view label) {
  const settings::Spec& trail = settings::spec(Id::kTrailMs);
  for (const settings::Stop& stop : trail.stops) {
    if (label == stop.label) return stop.value;
  }
  return trail.default_value;
}

// Functional: guides, meters with readouts, Medium response.
Settings mix() {
  Settings s;
  s.setChoice(Id::kGuides, "full");
  s.setNumber(Id::kCorrelationMeter, 1);
  s.setNumber(Id::kBalanceMeter, 1);
  s.setNumber(Id::kMeterReadouts, 1);
  s.setNumber(Id::kTrailMs, response("Medium"));
  return s;
}

// For filming: nothing but the picture, with glow and an Instant response.
Settings stage() {
  Settings s;
  s.setChoice(Id::kGuides, "off");
  s.setNumber(Id::kCorrelationMeter, 0);
  s.setNumber(Id::kBalanceMeter, 0);
  s.setNumber(Id::kGlow, 60);
  s.setNumber(Id::kBrightness, 120);
  s.setNumber(Id::kTrailMs, response("Instant"));
  return s;
}

// The original mode (its look is finished in Phase 2).
Settings original() {
  Settings s;
  s.setChoice(Id::kMode, "original");
  s.setNumber(Id::kGlow, 40);
  s.setNumber(Id::kTrailMs, response("Slow"));
  return s;
}

// A phosphor-green beam with full guides.
Settings classic() {
  Settings s;
  s.setChoice(Id::kMode, "goniometer");
  s.setChoice(Id::kDrawStyle, "lines");
  s.setChoice(Id::kGuides, "full");
  s.setChoice(Id::kColorMode, "solid");
  s.setNumber(Id::kSolidColor, 0x66FF99FF);
  s.setNumber(Id::kGlow, 30);
  s.setNumber(Id::kTrailMs, response("Slow"));
  return s;
}

fs::path homeFolder() {
  const long suggested = sysconf(_SC_GETPW_R_SIZE_MAX);
  std::string buffer(suggested > 0 ? static_cast<size_t>(suggested) : 16384, '\0');
  passwd entry{};
  passwd* result = nullptr;
  if (getpwuid_r(getuid(), &entry, buffer.data(), buffer.size(), &result) == 0 &&
      result != nullptr && result->pw_dir != nullptr && result->pw_dir[0] == '/') {
    return result->pw_dir;
  }
  const char* home = std::getenv("HOME");
  return home != nullptr && home[0] == '/' ? fs::path(home) : fs::path();
}

std::string lowered(std::string_view text) {
  std::string result(text);
  std::transform(result.begin(), result.end(), result.begin(), [](char c) {
    return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c;
  });
  return result;
}

std::error_code lastError() { return {errno, std::generic_category()}; }

// The name a preset file shows: its file name without the extension, control characters and
// invalid UTF-8. Not capped: Finder may give a file a longer name than save() writes.
std::string shownName(const fs::path& file) {
  const std::string stem = file.stem().string();
  return utf8::clean(stem, stem.size());
}

Status readOpen(int fd, std::string& text) {
  struct stat info {};
  if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) return Status::kUnreadable;
  if (static_cast<uintmax_t>(info.st_size) > settings::kMaxDocumentBytes) return Status::kTooLarge;
  text.resize(settings::kMaxDocumentBytes + 1);  // a file that grew meanwhile is still caught
  size_t filled = 0;
  while (filled < text.size()) {
    const ssize_t got = ::read(fd, text.data() + filled, text.size() - filled);
    if (got < 0) {
      if (errno == EINTR) continue;
      return Status::kUnreadable;
    }
    if (got == 0) break;
    filled += static_cast<size_t>(got);
  }
  text.resize(filled);
  return filled > settings::kMaxDocumentBytes ? Status::kTooLarge : Status::kOk;
}

// Opened once and checked through the descriptor, so a file swapped for a folder or a FIFO after
// a check is never read; O_NONBLOCK keeps the open of a FIFO from waiting for a writer.
Status readDocument(const fs::path& file, std::string& text) {
  const int fd = ::open(file.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return Status::kUnreadable;
  const Status status = readOpen(fd, text);
  ::close(fd);
  return status;
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

std::span<const Preset> factory() {
  static const Preset kFactory[] = {
      {"Mix", mix()},
      {"Stage", stage()},
      {NMR_VENDOR, original()},
      {"Classic", classic()},
  };
  return kFactory;
}

fs::path directory() {
  const fs::path home = homeFolder();
  if (home.empty()) return {};
  return home / "Library" / "Application Support" / NMR_SUPPORT_SUBDIR / "Presets";
}

std::vector<Entry> list(const fs::path& folder) {
  std::vector<Entry> entries;
  std::error_code error;
  for (fs::directory_iterator it(folder, error), end; !error && it != end; it.increment(error)) {
    const fs::path& path = it->path();
    const std::string name = path.filename().string();
    std::error_code type_error;
    if (name.starts_with('.') || path.extension() != ".json" || !it->is_regular_file(type_error)) {
      continue;
    }
    entries.push_back({shownName(path), path});
  }
  std::sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) {
    const std::string la = lowered(a.name);
    const std::string lb = lowered(b.name);
    if (la != lb) return la < lb;
    return a.name != b.name ? a.name < b.name : a.path < b.path;
  });
  return entries;
}

std::optional<Preset> load(const fs::path& file, Report& report) {
  report = Report{};
  std::string text;
  report.status = readDocument(file, text);
  if (report.status != Status::kOk) return std::nullopt;
  std::optional<Preset> preset = settings::decodePreset(text, report);
  if (preset) preset->name = shownName(file);
  return preset;
}

fs::path save(const fs::path& folder, const Preset& preset, std::error_code& error) {
  error.clear();
  fs::create_directories(folder, error);
  if (error) return {};
  const fs::path file = folder / fileName(preset.name);
  // A hidden temporary file in the same folder, renamed over the old file in one step.
  std::string temporary = (folder / ("." + file.filename().string() + ".XXXXXX")).string();
  const int fd = mkstemp(temporary.data());
  if (fd < 0) {
    error = lastError();
    return {};
  }
  error = writeAll(fd, settings::encodePreset(preset));
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

bool remove(const fs::path& file, std::error_code& error) {
  error.clear();
  if (::unlink(file.c_str()) != 0) {  // a folder fails (EPERM); fs::remove would delete it
    error = lastError();
    return false;
  }
  return true;
}

std::string fileName(std::string_view name) {
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
    if (result.size() + piece.size() > settings::kMaxPresetNameBytes) break;
    result += piece;
  }
  while (!result.empty() && result.back() == ' ') result.pop_back();
  return (result.empty() ? std::string("Preset") : result) + ".json";
}

}  // namespace nmr::presets
