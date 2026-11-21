#include <nmr/colormap.h>

#include <xlocale.h>

#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdlib>

#include "files.h"

namespace nmr::colormap {
namespace {

namespace fs = std::filesystem;

constexpr Rgba rgb(uint8_t r, uint8_t g, uint8_t b) { return {r, g, b, 255}; }

// The original set, bass (t = 0) to treble (t = 1). Each starts bright enough for bass-heavy
// material to show on a dark background, and ends near white for the brightest highs.
constexpr Stop kIris[] = {
    {0.00f, rgb(78, 70, 190)},    // deep violet
    {0.40f, rgb(137, 147, 255)},  // iris, #8993FF
    {0.75f, rgb(196, 202, 255)},
    {1.00f, rgb(244, 246, 255)},  // chrome white
};
constexpr Stop kChrome[] = {
    {0.00f, rgb(92, 98, 120)},    // dark steel
    {0.45f, rgb(168, 174, 192)},  // silver
    {0.70f, rgb(214, 220, 232)},
    {1.00f, rgb(255, 255, 255)},
};
constexpr Stop kBloodmoon[] = {
    {0.00f, rgb(120, 18, 44)},  // dried blood
    {0.45f, rgb(224, 60, 96)},  // #E03C60
    {0.80f, rgb(255, 150, 170)},
    {1.00f, rgb(255, 228, 234)},
};
constexpr Stop kPhosphor[] = {
    {0.00f, rgb(24, 112, 56)},
    {0.50f, rgb(64, 232, 112)},
    {0.85f, rgb(172, 255, 194)},
    {1.00f, rgb(236, 255, 240)},
};
constexpr Stop kAurora[] = {
    {0.00f, rgb(32, 178, 120)},   // green
    {0.35f, rgb(40, 170, 200)},   // cyan
    {0.65f, rgb(137, 147, 255)},  // iris
    {1.00f, rgb(236, 120, 220)},  // magenta
};
constexpr Stop kGlacier[] = {
    {0.00f, rgb(32, 76, 156)},
    {0.50f, rgb(92, 172, 232)},
    {0.85f, rgb(192, 232, 250)},
    {1.00f, rgb(245, 252, 255)},
};

constexpr Builtin kBuiltins[] = {
    {"iris", "Iris", kIris},
    {"chrome", "Chrome", kChrome},
    {"bloodmoon", "Bloodmoon", kBloodmoon},
    {"phosphor", "Phosphor", kPhosphor},
    {"aurora", "Aurora", kAurora},
    {"glacier", "Glacier", kGlacier},
};
static_assert(kBuiltins[0].key == kDefaultKey);

// The C API hands keys and labels out as C strings: each must be a whole string literal.
constexpr bool isCString(std::string_view text) { return text.data()[text.size()] == '\0'; }
static_assert(std::ranges::all_of(kBuiltins, [](const Builtin& map) {
  return isCString(map.key) && isCString(map.label);
}));

constexpr size_t kMaxNumberChars = 64;
constexpr size_t kMaxImportNameBytes = 100;  // like preset names

uint8_t mix(uint8_t from, uint8_t to, float f) {
  const float value =
      static_cast<float>(from) + (static_cast<float>(to) - static_cast<float>(from)) * f;
  return static_cast<uint8_t>(std::clamp(std::lround(value), 0L, 255L));
}

bool isSpace(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

char lower(char c) { return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c; }

// Reads the inside of one bracketed entry: "rgb(r, g, b); position", spaces anywhere between parts.
class Scanner {
 public:
  explicit Scanner(std::string_view text) : text_(text) {}

  bool take(char c) {
    skipSpace();
    if (at_ == text_.size() || text_[at_] != c) return false;
    ++at_;
    return true;
  }

  // An ASCII word, in any case.
  bool takeWord(std::string_view word) {
    skipSpace();
    if (text_.size() - at_ < word.size()) return false;
    for (size_t i = 0; i < word.size(); ++i) {
      if (lower(text_[at_ + i]) != word[i]) return false;
    }
    at_ += word.size();
    return true;
  }

  // Digits with at most one '.', nothing else (no sign or exponent), read in the C locale.
  std::optional<float> number() {
    skipSpace();
    const size_t start = at_;
    size_t digits = 0;
    size_t dots = 0;
    for (; at_ < text_.size(); ++at_) {
      const char c = text_[at_];
      if (c >= '0' && c <= '9') {
        ++digits;
      } else if (c == '.') {
        ++dots;
      } else {
        break;
      }
    }
    const size_t length = at_ - start;
    if (digits == 0 || dots > 1 || length > kMaxNumberChars) return std::nullopt;
    char buffer[kMaxNumberChars + 1];
    text_.copy(buffer, length, start);
    buffer[length] = '\0';
    return strtof_l(buffer, nullptr, LC_C_LOCALE);
  }

  bool atEnd() {
    skipSpace();
    return at_ == text_.size();
  }

 private:
  void skipSpace() {
    while (at_ < text_.size() && isSpace(text_[at_])) ++at_;
  }

  std::string_view text_;
  size_t at_ = 0;
};

struct Parsed {
  Stop stop;
  uint32_t clamped = 0;
};

std::optional<Parsed> parseEntry(std::string_view inside) {
  Scanner scan(inside);
  if (!scan.takeWord("rgba") && !scan.takeWord("rgb")) return std::nullopt;
  if (!scan.take('(')) return std::nullopt;
  float components[4] = {0, 0, 0, 255};
  size_t count = 0;
  do {
    if (count == 4) return std::nullopt;
    const std::optional<float> value = scan.number();
    if (!value) return std::nullopt;
    components[count++] = *value;
  } while (scan.take(','));
  if (count < 3 || !scan.take(')') || !scan.take(';')) return std::nullopt;
  const std::optional<float> position = scan.number();
  if (!position || !scan.atEnd()) return std::nullopt;

  Parsed parsed;
  const auto component = [&](float value) {
    if (value > 255.0f) {
      ++parsed.clamped;
      value = 255.0f;
    }
    return static_cast<uint8_t>(std::lround(value));
  };
  parsed.stop.color = {component(components[0]), component(components[1]),
                       component(components[2]), component(components[3])};
  parsed.stop.position = *position;
  if (parsed.stop.position > 1.0f) {
    ++parsed.clamped;
    parsed.stop.position = 1.0f;
  }
  return parsed;
}

// `text` with every "//" comment removed up to its line's end, CR or LF (the line break stays).
std::string withoutComments(std::string_view text) {
  std::string result;
  result.reserve(text.size());
  for (size_t at = 0; at < text.size(); ++at) {
    if (text[at] == '/' && at + 1 < text.size() && text[at + 1] == '/') {
      at = text.find_first_of("\r\n", at);
      if (at == std::string_view::npos) break;
    }
    result += text[at];
  }
  return result;
}

void appendPosition(std::string& out, float position) {
  // In 0…1, never -0, in fixed notation: the shortest digits that read back as the same float.
  const float value = (position >= 0.0f ? std::min(position, 1.0f) : 0.0f) + 0.0f;
  char buffer[64];
  const std::to_chars_result written =
      std::to_chars(buffer, buffer + sizeof buffer, value, std::chars_format::fixed);
  const std::string_view digits(buffer, written.ec == std::errc{} ? written.ptr - buffer : 0);
  out += digits.empty() ? std::string_view("0") : digits;
  if (digits.find('.') == std::string_view::npos) out += ".0";
}

std::vector<Stop> copyOf(std::span<const Stop> stops) { return {stops.begin(), stops.end()}; }

}  // namespace

std::span<const Builtin> builtins() noexcept { return kBuiltins; }

const Builtin* findBuiltin(std::string_view key) noexcept {
  for (const Builtin& builtin : kBuiltins) {
    if (builtin.key == key) return &builtin;
  }
  return nullptr;
}

Rgba sample(std::span<const Stop> stops, float t) noexcept {
  if (stops.empty()) return {0, 0, 0, 0};
  t = t >= 0.0f ? std::min(t, 1.0f) : 0.0f;  // NaN reads as 0
  // The first stop past t; the one before it is the last stop at or before t.
  const auto after =
      std::upper_bound(stops.begin(), stops.end(), t,
                       [](float value, const Stop& stop) { return value < stop.position; });
  if (after == stops.begin()) return stops.front().color;
  const Stop& at = *(after - 1);
  if (after == stops.end()) return at.color;
  const float f = (t - at.position) / (after->position - at.position);
  return {mix(at.color.r, after->color.r, f), mix(at.color.g, after->color.g, f),
          mix(at.color.b, after->color.b, f), mix(at.color.a, after->color.a, f)};
}

Table table(std::span<const Stop> stops) noexcept {
  Table result;
  for (size_t i = 0; i < kTableSize; ++i) {
    result[i] = sample(stops, static_cast<float>(i) / static_cast<float>(kTableSize - 1));
  }
  return result;
}

std::optional<std::vector<Stop>> parseMap(std::string_view text, Report& report) {
  report = Report{};
  if (text.size() > kMaxMapBytes) {
    report.status = Status::kTooLarge;
    return std::nullopt;
  }
  const std::string cleaned = withoutComments(text);
  const std::string_view rest = cleaned;
  std::vector<Stop> stops;
  for (size_t open = rest.find('['); open != std::string_view::npos;) {
    const size_t close = rest.find_first_of("[]", open + 1);
    if (close == std::string_view::npos || rest[close] == '[') {  // never closed
      ++report.skipped;
      open = close;
      continue;
    }
    const std::optional<Parsed> parsed = parseEntry(rest.substr(open + 1, close - open - 1));
    if (!parsed || stops.size() == kMaxStops) {
      ++report.skipped;
    } else {
      stops.push_back(parsed->stop);
      report.adjusted += parsed->clamped;
    }
    open = rest.find('[', close + 1);
  }
  if (stops.empty()) {
    report.status = Status::kNoStops;
    return std::nullopt;
  }
  std::stable_sort(stops.begin(), stops.end(),
                   [](const Stop& a, const Stop& b) { return a.position < b.position; });
  return stops;
}

std::string formatMap(std::span<const Stop> stops) {
  std::string out;
  for (const Stop& stop : stops) {
    const Rgba& c = stop.color;
    out += c.a == 255 ? "[rgb(" : "[rgba(";
    out += std::to_string(c.r) + ", " + std::to_string(c.g) + ", " + std::to_string(c.b);
    if (c.a != 255) out += ", " + std::to_string(c.a);
    out += "); ";
    appendPosition(out, stop.position);
    out += "]\n";
  }
  return out;
}

fs::path directory() { return files::supportFolder("Colormaps"); }

std::vector<UserFile> list(const fs::path& folder) { return files::list(folder, ".map"); }

std::optional<std::vector<Stop>> load(const fs::path& file, Report& report) {
  report = Report{};
  std::string text;
  switch (files::read(file, kMaxMapBytes, text)) {
    case files::Read::kOk:
      return parseMap(text, report);
    case files::Read::kTooLarge:
      report.status = Status::kTooLarge;
      return std::nullopt;
    case files::Read::kUnreadable:
      report.status = Status::kUnreadable;
      return std::nullopt;
  }
  return std::nullopt;
}

fs::path importMap(const fs::path& folder, const fs::path& source, Report& report,
                   std::error_code& error) {
  error.clear();
  const std::optional<std::vector<Stop>> stops = load(source, report);
  if (!stops) return {};
  const std::string name =
      files::fileName(files::shownName(source), kMaxImportNameBytes, "Colormap", ".map");
  return files::write(folder, name, formatMap(*stops), error);
}

bool remove(const fs::path& file, std::error_code& error) { return files::remove(file, error); }

std::string userKey(std::string_view name) {
  std::string key(kUserPrefix);
  return key += name;
}

std::vector<Stop> resolve(std::string_view key, const fs::path& folder, bool* found) {
  const auto answer = [&](std::vector<Stop> stops, bool known) {
    if (found != nullptr) *found = known;
    return stops;
  };
  if (const Builtin* builtin = findBuiltin(key)) return answer(copyOf(builtin->stops), true);
  if (key.starts_with(kUserPrefix) && !folder.empty()) {
    const std::string_view name = key.substr(kUserPrefix.size());
    // Two files listed under one name (they differ only in control characters or invalid UTF-8):
    // the first listed wins.
    for (const UserFile& file : list(folder)) {
      if (file.name != name) continue;
      Report report;
      if (std::optional<std::vector<Stop>> stops = load(file.path, report)) {
        return answer(std::move(*stops), true);
      }
      break;
    }
  }
  return answer(copyOf(kBuiltins[0].stops), false);
}

}  // namespace nmr::colormap
