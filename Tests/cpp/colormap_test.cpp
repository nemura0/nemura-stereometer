// Colormaps: the original set, sampling, .map files and the user's colormap folder
// (Sources/Core/include/nmr/colormap.h).
#include <doctest/doctest.h>
#include <nmr/colormap.h>
#include <nmr/product_config.h>
#include <nmr/settings.h>

#include <algorithm>
#include <clocale>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <limits>
#include <optional>
#include <random>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

#include "test_files.h"

namespace cm = nmr::colormap;
namespace fs = std::filesystem;
namespace st = nmr::settings;
using cm::Rgba;
using cm::Stop;
using nmr::test::readFile;
using nmr::test::TempFolder;
using nmr::test::writeFile;

namespace {

constexpr Rgba rgb(uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255) { return {r, g, b, a}; }

std::vector<Stop> parsed(std::string_view text, cm::Report& report) {
  const std::optional<std::vector<Stop>> stops = cm::parseMap(text, report);
  REQUIRE_MESSAGE(stops.has_value(), std::string(text.substr(0, 200)));
  CHECK(report.status == cm::Status::kOk);
  return *stops;
}

std::vector<Stop> stopsOf(std::string_view key) {
  const cm::Builtin* map = cm::findBuiltin(key);
  REQUIRE_MESSAGE(map != nullptr, std::string(key));
  return {map->stops.begin(), map->stops.end()};
}

// Switches the process to a locale that writes decimals with a comma, and back afterwards.
class CommaLocale {
 public:
  CommaLocale() {
    const char* current = std::setlocale(LC_ALL, nullptr);
    saved_ = current != nullptr ? current : "C";
    for (const char* name : {"de_DE.UTF-8", "fr_FR.UTF-8", "es_ES.UTF-8", "nl_NL.UTF-8"}) {
      if (std::setlocale(LC_ALL, name) != nullptr && std::localeconv()->decimal_point[0] == ',') {
        active_ = true;
        break;
      }
    }
  }
  ~CommaLocale() { std::setlocale(LC_ALL, saved_.c_str()); }
  CommaLocale(const CommaLocale&) = delete;
  CommaLocale& operator=(const CommaLocale&) = delete;

  [[nodiscard]] bool active() const { return active_; }

 private:
  std::string saved_;
  bool active_ = false;
};

}  // namespace

// ---- The original set ------------------------------------------------------------------------

TEST_CASE("built-in colormaps: six originals, Iris first and the settings default") {
  std::vector<std::string_view> keys;
  std::vector<std::string_view> labels;
  for (const cm::Builtin& map : cm::builtins()) {
    keys.push_back(map.key);
    labels.push_back(map.label);
  }
  CHECK(keys == std::vector<std::string_view>{"iris", "chrome", "bloodmoon", "phosphor", "aurora",
                                              "glacier"});
  CHECK(labels == std::vector<std::string_view>{"Iris", "Chrome", "Bloodmoon", "Phosphor", "Aurora",
                                                "Glacier"});
  REQUIRE_FALSE(keys.empty());
  CHECK(keys.front() == cm::kDefaultKey);
  const st::Spec& setting = st::spec(st::Id::kColormap);
  CHECK(std::string_view(setting.default_text) == cm::kDefaultKey);
  CHECK(setting.max_length == cm::kMaxKeyBytes);
}

TEST_CASE("built-in colormaps: sorted, opaque, from 0 to 1, bass visible, all different") {
  REQUIRE(cm::builtins().size() == 6);
  std::vector<cm::Table> tables;
  for (const cm::Builtin& map : cm::builtins()) {
    CAPTURE(map.key);
    CHECK(cm::findBuiltin(map.key) == &map);
    REQUIRE(map.stops.size() >= 2);
    CHECK(map.stops.front().position == 0.0f);
    CHECK(map.stops.back().position == 1.0f);
    for (size_t i = 1; i < map.stops.size(); ++i) {
      CHECK(map.stops[i - 1].position < map.stops[i].position);
    }
    for (const Stop& stop : map.stops) CHECK(stop.color.a == 255);
    const Rgba bass = map.stops.front().color;  // t = 0: bass only, on a dark background
    CHECK(std::max({bass.r, bass.g, bass.b}) >= 80);
    const cm::Table table = cm::table(map.stops);
    for (const cm::Table& other : tables) CHECK_FALSE(other == table);
    tables.push_back(table);
  }
}

TEST_CASE("built-in colormaps: Iris and Bloodmoon are built on the brand colors; keys are exact") {
  const auto passesThrough = [](std::string_view key, Rgba color) {
    const std::vector<Stop> stops = stopsOf(key);
    return std::any_of(stops.begin(), stops.end(),
                       [&](const Stop& stop) { return stop.color == color; });
  };
  CHECK(passesThrough("iris", rgb(0x89, 0x93, 0xFF)));
  CHECK(passesThrough("bloodmoon", rgb(0xE0, 0x3C, 0x60)));
  CHECK(cm::findBuiltin("Iris") == nullptr);
  CHECK(cm::findBuiltin("") == nullptr);
  CHECK(cm::findBuiltin("user:iris") == nullptr);
}

// ---- Sampling --------------------------------------------------------------------------------

TEST_CASE("sampling: linear between stops in sRGB, clamped outside them") {
  const std::vector<Stop> stops = {
      {0.0f, rgb(0, 0, 0)}, {0.5f, rgb(200, 100, 50)}, {1.0f, rgb(255, 255, 255, 55)}};
  CHECK(cm::sample(stops, 0.0f) == rgb(0, 0, 0));
  CHECK(cm::sample(stops, 0.25f) == rgb(100, 50, 25));
  CHECK(cm::sample(stops, 0.5f) == rgb(200, 100, 50));
  CHECK(cm::sample(stops, 0.75f) == rgb(228, 178, 153, 155));  // halves round up
  CHECK(cm::sample(stops, 1.0f) == rgb(255, 255, 255, 55));
  CHECK(cm::sample(stops, -1.0f) == rgb(0, 0, 0));
  CHECK(cm::sample(stops, 2.0f) == rgb(255, 255, 255, 55));
  CHECK(cm::sample(stops, std::numeric_limits<float>::quiet_NaN()) == rgb(0, 0, 0));
  CHECK(cm::sample(stops, std::numeric_limits<float>::infinity()) == rgb(255, 255, 255, 55));
  CHECK(cm::sample(stops, -std::numeric_limits<float>::infinity()) == rgb(0, 0, 0));

  // Stops that start after 0 or end before 1: the end colors hold.
  const std::vector<Stop> inner = {{0.25f, rgb(10, 20, 30)}, {0.75f, rgb(30, 40, 50)}};
  CHECK(cm::sample(inner, 0.1f) == rgb(10, 20, 30));
  CHECK(cm::sample(inner, 0.5f) == rgb(20, 30, 40));
  CHECK(cm::sample(inner, 0.9f) == rgb(30, 40, 50));
}

TEST_CASE("sampling: a hard edge, a single stop, no stops") {
  // Black fades to red up to 0.5, where blue takes over.
  const std::vector<Stop> edge = {{0.0f, rgb(0, 0, 0)},
                                  {0.5f, rgb(255, 0, 0)},
                                  {0.5f, rgb(0, 0, 255)},
                                  {1.0f, rgb(0, 0, 255)}};
  const Rgba before = cm::sample(edge, 0.4999f);
  CHECK(before.r > 250);
  CHECK(before.b == 0);
  CHECK(cm::sample(edge, 0.5f) == rgb(0, 0, 255));

  const std::vector<Stop> single = {{0.3f, rgb(1, 2, 3, 4)}};
  for (const float t : {0.0f, 0.3f, 1.0f}) CHECK(cm::sample(single, t) == rgb(1, 2, 3, 4));
  CHECK(cm::sample({}, 0.5f) == Rgba{0, 0, 0, 0});
}

TEST_CASE("tables: 256 samples from 0 to 1") {
  const std::vector<Stop> iris = stopsOf("iris");
  const cm::Table table = cm::table(iris);
  for (size_t i = 0; i < cm::kTableSize; ++i) {
    CAPTURE(i);
    CHECK(table[i] == cm::sample(iris, static_cast<float>(i) / 255.0f));
  }
  CHECK(table.front() == iris.front().color);
  CHECK(table.back() == iris.back().color);
}

// ---- .map files ------------------------------------------------------------------------------

TEST_CASE(".map files: rgb and rgba stops, any spacing, comments, any order") {
  cm::Report report;
  const std::vector<Stop> stops = parsed(
      "[rgb(255, 128, 0); 1.0]  // orange\n"
      "\n"
      "[ rgba( 10 ,20,30 , 40 ) ; .25 ]\r\n"
      "[RGB(1, 2, 3); 0]\n"
      "[rgba(4, 5, 6); 0.5]\n"
      "[rgb(7, 8, 9, 10);\n 0.75]\n",
      report);
  CHECK(report.skipped == 0);
  CHECK(report.adjusted == 0);
  CHECK(stops == std::vector<Stop>{{0.0f, rgb(1, 2, 3)},
                                   {0.25f, rgb(10, 20, 30, 40)},
                                   {0.5f, rgb(4, 5, 6)},
                                   {0.75f, rgb(7, 8, 9, 10)},
                                   {1.0f, rgb(255, 128, 0)}});
}

TEST_CASE(".map files: a comment ends at any line break, old Mac ones included") {
  cm::Report report;
  CHECK(parsed("[rgb(1, 2, 3); 0.25] // first\r[rgb(4, 5, 6); 0.75] // second\r", report) ==
        std::vector<Stop>{{0.25f, rgb(1, 2, 3)}, {0.75f, rgb(4, 5, 6)}});
  CHECK(report.skipped == 0);
}

TEST_CASE(".map files: numbers of up to 64 characters, positions down to the smallest float") {
  cm::Report report;
  const std::string component = std::string(61, '0') + "255";  // 64 characters
  CHECK(parsed("[rgb(" + component + ", 0, 0); 0.5]", report) ==
        std::vector<Stop>{{0.5f, rgb(255, 0, 0)}});
  CHECK_FALSE(cm::parseMap("[rgb(0" + component + ", 0, 0); 0.5]", report).has_value());
  CHECK(report.skipped == 1);

  // 1e-40 is below the smallest normal float: kept as written, neither 0 nor counted.
  const std::vector<Stop> tiny = parsed("[rgb(1, 2, 3); 0." + std::string(39, '0') + "1]", report);
  REQUIRE(tiny.size() == 1);
  CHECK(tiny[0].position > 0.0f);
  CHECK(tiny[0].position < std::numeric_limits<float>::min());
  CHECK(report.adjusted == 0);
  CHECK(parsed(cm::formatMap(tiny), report) == tiny);
}

TEST_CASE(".map files: sorted by position, stops sharing one keep the file's order") {
  cm::Report report;
  CHECK(parsed("[rgb(9, 9, 9); 1.0][rgb(1, 1, 1); 0.5][rgb(2, 2, 2); 0.5][rgb(0, 0, 0); 0.0]",
               report) == std::vector<Stop>{{0.0f, rgb(0, 0, 0)},
                                            {0.5f, rgb(1, 1, 1)},
                                            {0.5f, rgb(2, 2, 2)},
                                            {1.0f, rgb(9, 9, 9)}});

  // Enough stops that an unstable sort would reorder them (small arrays sort stably anyway).
  std::string text;
  std::vector<Stop> expected;
  for (int i = 0; i < 100; ++i) {
    const bool high = i % 2 == 0;  // alternate ends, so the sort has work to do
    const auto shade = static_cast<uint8_t>(i);
    text += "[rgb(" + std::to_string(i) + ", 0, 0); " + (high ? "0.75]" : "0.25]");
    expected.push_back({high ? 0.75f : 0.25f, rgb(shade, 0, 0)});
  }
  std::stable_sort(expected.begin(), expected.end(),
                   [](const Stop& a, const Stop& b) { return a.position < b.position; });
  CHECK(parsed(text, report) == expected);
}

TEST_CASE(".map files: values above their range are clamped and counted, decimals rounded") {
  cm::Report report;
  CHECK(parsed("[rgb(300, 255.6, 0.4); 1.5][rgba(127.5, 1, 2, 999); 0.5][rgb(254.5, 0, 0); 0.25]",
               report) == std::vector<Stop>{{0.25f, rgb(255, 0, 0)},
                                            {0.5f, rgb(128, 1, 2, 255)},
                                            {1.0f, rgb(255, 255, 0)}});
  CHECK(report.adjusted == 4);  // 300, 255.6, 1.5 and 999
  CHECK(report.skipped == 0);
}

TEST_CASE(".map files: malformed entries are skipped and counted; other text is ignored") {
  cm::Report report;
  const std::vector<Stop> stops = parsed(
      "My colormap\n"
      "[rgb(1, 2, 3); 0.5]  // [rgb(9, 9, 9); 0.9]\n"
      "[hsl(1, 2, 3); 0.1]\n"
      "[rgb(1, 2); 0.2]\n"
      "[rgb(1, 2, 3, 4, 5); 0.3]\n"
      "[rgb(1, -2, 3); 0.4]\n"
      "[rgb(1, 2, 3); 1e-1]\n"
      "[rgb(1, 2, 3); .]\n"
      "[rgb(1, 2, 3) 0.6]\n"
      "[rgb(1, 2, 3); 0.7; 0.8]\n"
      "[rgb(1, 2.3.4, 3); 0.9]\n"
      "[rgb(1, 2, 3)]\n"
      "[]\n"
      "[rgb(7, 8, 9); [rgb(4, 5, 6); 0.25]\n"  // the first is never closed
      "[rgb(4, 5, 6); 0.75",                    // nor is the last
      report);
  CHECK(stops == std::vector<Stop>{{0.25f, rgb(4, 5, 6)}, {0.5f, rgb(1, 2, 3)}});
  CHECK(report.skipped == 13);
  CHECK(report.adjusted == 0);
}

TEST_CASE(".map files: no stops, or more than 64 KiB, is refused") {
  cm::Report report;
  CHECK_FALSE(cm::parseMap("", report).has_value());
  CHECK(report.status == cm::Status::kNoStops);
  CHECK_FALSE(cm::parseMap("// nothing\n[rgb(1, 2); 0.5]", report).has_value());
  CHECK(report.status == cm::Status::kNoStops);
  CHECK(report.skipped == 1);

  const std::string stop = "[rgb(1, 2, 3); 0.5]";
  std::string padded = stop + std::string(cm::kMaxMapBytes - stop.size(), ' ');
  REQUIRE(padded.size() == cm::kMaxMapBytes);
  CHECK(parsed(padded, report) == std::vector<Stop>{{0.5f, rgb(1, 2, 3)}});
  padded += ' ';
  CHECK_FALSE(cm::parseMap(padded, report).has_value());
  CHECK(report.status == cm::Status::kTooLarge);
}

TEST_CASE(".map files: at most 256 stops, the first ones in the file") {
  std::string text;
  for (int i = 0; i < 300; ++i) {
    const std::string thousandths = std::to_string(1000 + i).substr(1);  // "000" … "299"
    text += "[rgb(" + std::to_string(i % 256) + ", 0, 0); 0." + thousandths + "]\n";
  }
  cm::Report report;
  const std::vector<Stop> stops = parsed(text, report);
  REQUIRE(stops.size() == cm::kMaxStops);
  CHECK(report.skipped == 300 - cm::kMaxStops);
  CHECK(stops.front() == Stop{0.0f, rgb(0, 0, 0)});
  CHECK(stops.back() == Stop{0.255f, rgb(255, 0, 0)});
}

TEST_CASE(".map files: read and written the same under a locale with decimal commas") {
  const CommaLocale locale;
  REQUIRE(locale.active());
  cm::Report report;
  CHECK(parsed("[rgb(1, 2, 3); 0.5][rgb(4, 5, 6); 0.25]", report) ==
        std::vector<Stop>{{0.25f, rgb(4, 5, 6)}, {0.5f, rgb(1, 2, 3)}});
  CHECK(cm::formatMap(std::vector<Stop>{{0.25f, rgb(4, 5, 6)}}) == "[rgb(4, 5, 6); 0.25]\n");
}

TEST_CASE(".map files: formatMap writes one stop per line that parseMap reads back unchanged") {
  CHECK(cm::formatMap(std::vector<Stop>{
            {0.0f, rgb(1, 2, 3)}, {0.5f, rgb(4, 5, 6, 7)}, {1.0f, rgb(8, 9, 10)}}) ==
        "[rgb(1, 2, 3); 0.0]\n[rgba(4, 5, 6, 7); 0.5]\n[rgb(8, 9, 10); 1.0]\n");
  CHECK(cm::formatMap({}).empty());
  // Positions outside 0…1 (from callers, never from parseMap) are written clamped, so the text
  // always reads back.
  CHECK(cm::formatMap(std::vector<Stop>{{-0.5f, rgb(1, 1, 1)},
                                        {-0.0f, rgb(2, 2, 2)},
                                        {std::numeric_limits<float>::quiet_NaN(), rgb(3, 3, 3)},
                                        {2.0f, rgb(4, 4, 4)}}) ==
        "[rgb(1, 1, 1); 0.0]\n[rgb(2, 2, 2); 0.0]\n[rgb(3, 3, 3); 0.0]\n[rgb(4, 4, 4); 1.0]\n");
  for (const cm::Builtin& map : cm::builtins()) {
    CAPTURE(map.key);
    cm::Report report;
    CHECK(parsed(cm::formatMap(map.stops), report) == stopsOf(map.key));
  }

  std::mt19937 random(11);
  std::uniform_real_distribution<float> position(0.0f, 1.0f);
  const auto byte = [&] { return static_cast<uint8_t>(random()); };
  for (int round = 0; round < 200; ++round) {
    std::vector<Stop> stops(1 + random() % 24);
    for (Stop& stop : stops) {
      // Every tenth map has tiny positions, which must be written without exponents.
      stop.position = round % 10 == 0 ? std::ldexp(position(random), -20) : position(random);
      stop.color = rgb(byte(), byte(), byte(), random() % 2 == 0 ? 255 : byte());
    }
    std::stable_sort(stops.begin(), stops.end(),
                     [](const Stop& a, const Stop& b) { return a.position < b.position; });
    const std::string text = cm::formatMap(stops);
    CAPTURE(text);
    cm::Report report;
    CHECK(parsed(text, report) == stops);
    CHECK(report.skipped == 0);
    CHECK(report.adjusted == 0);
  }
}

// ---- The user's colormaps --------------------------------------------------------------------

TEST_CASE("user colormaps: imported under the source's name, listed, loaded, resolved, removed") {
  TempFolder temp;
  const fs::path source = temp.path() / "Sunset Glow.map";
  writeFile(source, "[rgb(255, 0, 0); 1.0]\n[rgb(0, 0, 0); 0.0]  // dark\n");
  const fs::path folder = temp.path() / "Colormaps";  // importMap creates it
  cm::Report report;
  std::error_code error;
  const fs::path file = cm::importMap(folder, source, report, error);
  CHECK_FALSE(error);
  CHECK(report.status == cm::Status::kOk);
  CHECK(file == folder / "Sunset Glow.map");
  CHECK(readFile(file) == "[rgb(0, 0, 0); 0.0]\n[rgb(255, 0, 0); 1.0]\n");  // normalized

  const std::vector<Stop> expected = {{0.0f, rgb(0, 0, 0)}, {1.0f, rgb(255, 0, 0)}};
  const std::vector<nmr::UserFile> listed = cm::list(folder);
  REQUIRE(listed.size() == 1);
  CHECK(listed[0].name == "Sunset Glow");
  CHECK(listed[0].path == file);
  const std::optional<std::vector<Stop>> loaded = cm::load(file, report);
  REQUIRE(loaded.has_value());
  CHECK(*loaded == expected);

  bool found = false;
  CHECK(cm::userKey("Sunset Glow") == "user:Sunset Glow");
  CHECK(cm::resolve(cm::userKey("Sunset Glow"), folder, &found) == expected);
  CHECK(found);

  // Importing a file of the same name replaces the colormap.
  writeFile(source, "[rgb(0, 0, 255); 0.5]");
  CHECK(cm::importMap(folder, source, report, error) == file);
  CHECK(cm::resolve(cm::userKey("Sunset Glow"), folder) ==
        std::vector<Stop>{{0.5f, rgb(0, 0, 255)}});
  CHECK(cm::list(folder).size() == 1);

  CHECK(cm::remove(file, error));
  CHECK_FALSE(error);
  CHECK(cm::list(folder).empty());
  CHECK(cm::resolve(cm::userKey("Sunset Glow"), folder, &found) == stopsOf("iris"));
  CHECK_FALSE(found);
  CHECK_FALSE(cm::remove(folder, error));  // never a folder
  CHECK(error);
  CHECK(fs::is_directory(folder));

  const fs::path other = temp.path() / "Notes.txt";  // never a file that is not a colormap
  writeFile(other, "keep");
  CHECK_FALSE(cm::remove(other, error));
  CHECK(error == std::errc::invalid_argument);
  CHECK(fs::exists(other));
  const fs::path upper = folder / "Loud.MAP";
  writeFile(upper, "[rgb(1, 2, 3); 0]");
  CHECK(cm::remove(upper, error));
  CHECK_FALSE(fs::exists(upper));
}

TEST_CASE("user colormaps: a source without stops, unreadable or too large is not imported") {
  TempFolder temp;
  const fs::path folder = temp.path() / "Colormaps";
  cm::Report report;
  std::error_code error;
  writeFile(temp.path() / "Empty.map", "nothing here");
  CHECK(cm::importMap(folder, temp.path() / "Empty.map", report, error).empty());
  CHECK(report.status == cm::Status::kNoStops);
  CHECK_FALSE(error);
  CHECK(cm::importMap(folder, temp.path() / "Missing.map", report, error).empty());
  CHECK(report.status == cm::Status::kUnreadable);
  writeFile(temp.path() / "Huge.map", std::string(cm::kMaxMapBytes + 1, ' '));
  CHECK(cm::importMap(folder, temp.path() / "Huge.map", report, error).empty());
  CHECK(report.status == cm::Status::kTooLarge);
  fs::create_directory(temp.path() / "Folder.map");
  CHECK(cm::importMap(folder, temp.path() / "Folder.map", report, error).empty());
  CHECK(report.status == cm::Status::kUnreadable);
  CHECK_FALSE(fs::exists(folder));  // nothing was written

  writeFile(temp.path() / "file", "");
  writeFile(temp.path() / "Fine.map", "[rgb(1, 2, 3); 0.5]");
  CHECK(cm::importMap(temp.path() / "file" / "Colormaps", temp.path() / "Fine.map", report, error)
            .empty());
  CHECK(report.status == cm::Status::kOk);
  CHECK(error);
}

TEST_CASE("colormap keys: built-ins by key, user colormaps by listed name, Iris otherwise") {
  TempFolder temp;
  const fs::path& folder = temp.path();
  writeFile(folder / "Odd\x01Name.map", "[rgb(1, 2, 3); 0.5]");
  writeFile(folder / "Broken.map", "no stops");
  bool found = false;
  CHECK(cm::resolve("chrome", folder, &found) == stopsOf("chrome"));
  CHECK(found);
  CHECK(cm::resolve(cm::userKey("OddName"), folder, &found) ==
        std::vector<Stop>{{0.5f, rgb(1, 2, 3)}});
  CHECK(found);
  for (const std::string key : {"", "Chrome", "user:", "user:Broken", "user:Missing",
                                "user:../Broken", "user:Odd\x01Name"}) {
    CAPTURE(key);
    found = true;
    CHECK(cm::resolve(key, folder, &found) == stopsOf("iris"));
    CHECK_FALSE(found);
  }
  CHECK(cm::resolve(cm::userKey("OddName"), fs::path(), &found) == stopsOf("iris"));  // no folder
  CHECK_FALSE(found);
  CHECK(cm::resolve("iris", fs::path()) == stopsOf("iris"));
}

TEST_CASE("colormap keys: the key of any file the folder can hold fits the colormap setting") {
  TempFolder temp;
  const std::string longest(255 - 4, 'n');  // NAME_MAX bytes with ".map"
  writeFile(temp.path() / (longest + ".map"), "[rgb(1, 2, 3); 0.5]");
  const std::string key = cm::userKey(longest);
  CHECK(key.size() == cm::kMaxKeyBytes);
  bool found = false;
  CHECK(cm::resolve(key, temp.path(), &found) == std::vector<Stop>{{0.5f, rgb(1, 2, 3)}});
  CHECK(found);

  st::Settings settings;
  CHECK(settings.setText(st::Id::kColormap, key) == st::Change::kSet);
  CHECK(settings.setText(st::Id::kColormap, key + "n") == st::Change::kRejected);

  const fs::path folder = cm::directory();
  CHECK(folder.is_absolute());
  CHECK(folder.string().ends_with("/Library/Application Support/" NMR_SUPPORT_SUBDIR "/Colormaps"));
}
