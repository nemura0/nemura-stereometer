// Presets: the factory set and the preset files (Sources/Core/include/nmr/presets.h).
#include <doctest/doctest.h>
#include <nmr/presets.h>
#include <nmr/product_config.h>

#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

#include "test_files.h"

namespace fs = std::filesystem;
namespace st = nmr::settings;
namespace presets = nmr::presets;
using nmr::test::TempFolder;
using nmr::test::writeFile;
using st::Id;

namespace {

std::vector<std::string> listedNames(const fs::path& folder) {
  std::vector<std::string> names;
  for (const presets::Entry& entry : presets::list(folder)) {
    CHECK(entry.path == folder / (entry.name + ".json"));
    names.push_back(entry.name);
  }
  return names;
}

size_t entriesIn(const fs::path& folder) {
  return static_cast<size_t>(
      std::distance(fs::directory_iterator(folder), fs::directory_iterator()));
}

const st::Preset& factoryPreset(std::string_view name) {
  const std::span<const st::Preset> all = presets::factory();
  const auto found =
      std::find_if(all.begin(), all.end(), [&](const st::Preset& p) { return p.name == name; });
  REQUIRE_MESSAGE(found != all.end(), std::string(name));
  return *found;
}

}  // namespace

// ---- Factory presets -------------------------------------------------------------------------

TEST_CASE("factory presets: Mix, Stage, the original mode and Classic, as the brief describes") {
  std::vector<std::string> names;
  for (const st::Preset& preset : presets::factory()) names.push_back(preset.name);
  CHECK(names == std::vector<std::string>{"Mix", "Stage", NMR_VENDOR, "Classic"});

  const std::span<const st::Stop> response = st::spec(Id::kTrailMs).stops;
  REQUIRE(response.size() == 5);

  const st::Settings& mix = factoryPreset("Mix").settings;  // functional
  CHECK(mix.choiceKey(Id::kGuides) == "full");
  CHECK(mix.flag(Id::kCorrelationMeter));
  CHECK(mix.flag(Id::kBalanceMeter));
  CHECK(mix.number(Id::kTrailMs) == response[2].value);  // Medium

  const st::Settings& stage = factoryPreset("Stage").settings;  // for filming
  CHECK(stage.choiceKey(Id::kGuides) == "off");
  CHECK(stage.number(Id::kGlow) > 0);
  CHECK(stage.number(Id::kTrailMs) == response[0].value);  // Instant

  CHECK(factoryPreset(NMR_VENDOR).settings.choiceKey(Id::kMode) == "original");
  CHECK(factoryPreset("Classic").settings.choiceKey(Id::kMode) == "goniometer");
}

TEST_CASE("factory presets: each survives JSON unchanged, and no two look the same") {
  REQUIRE(presets::factory().size() == 4);
  std::vector<st::Settings> looks;
  for (const st::Preset& preset : presets::factory()) {
    CAPTURE(preset.name);
    st::Report report;
    const std::optional<st::Preset> decoded = st::decodePreset(st::encodePreset(preset), report);
    REQUIRE(decoded.has_value());
    CHECK(*decoded == preset);  // so its entries outside presets are the defaults
    CHECK(report.status == st::Status::kOk);
    CHECK(report.ignored == 0);
    CHECK(report.invalid == 0);
    CHECK(report.adjusted == 0);
    CHECK(presets::fileName(preset.name) == preset.name + ".json");
    for (const st::Settings& other : looks) CHECK_FALSE(other == preset.settings);
    looks.push_back(preset.settings);
  }
}

// ---- Preset files ----------------------------------------------------------------------------

TEST_CASE("preset folder: Application Support in the real home, whatever HOME says") {
  const fs::path folder = presets::directory();
  CHECK(folder.is_absolute());
  const std::string suffix = "/Library/Application Support/" NMR_SUPPORT_SUBDIR "/Presets";
  CHECK(folder.string().size() > suffix.size());
  CHECK(folder.string().ends_with(suffix));

  // A sandboxed host points HOME at its container; the presets stay where the app keeps them.
  const char* home = std::getenv("HOME");
  const bool had_home = home != nullptr;
  const std::string saved_home = had_home ? home : "";
  REQUIRE(setenv("HOME", "/private/tmp/nmr-elsewhere", 1) == 0);
  CHECK(presets::directory() == folder);
  if (had_home) {
    setenv("HOME", saved_home.c_str(), 1);
  } else {
    unsetenv("HOME");
  }
}

TEST_CASE("preset files: saved under the preset's name, loaded, replaced and removed") {
  TempFolder temp;
  const fs::path folder = temp.path() / "Presets";  // save creates it
  CHECK(presets::list(folder).empty());

  st::Settings look;
  REQUIRE(look.setChoice(Id::kGuides, "full") == st::Change::kSet);
  REQUIRE(look.setNumber(Id::kGlow, 35) == st::Change::kSet);
  std::error_code error;
  const fs::path file = presets::save(folder, {"Late Night", look}, error);
  CHECK_FALSE(error);
  CHECK(file == folder / "Late Night.json");
  CHECK((fs::status(file).permissions() & fs::perms::mask) ==
        (fs::perms::owner_read | fs::perms::owner_write));  // private to the account

  st::Report report;
  std::optional<st::Preset> loaded = presets::load(file, report);
  REQUIRE(loaded.has_value());
  CHECK(report.status == st::Status::kOk);
  CHECK(*loaded == st::Preset{"Late Night", look});

  // Saving again replaces the file and leaves nothing else behind.
  REQUIRE(look.setChoice(Id::kGuides, "off") == st::Change::kSet);
  CHECK(presets::save(folder, {"Late Night", look}, error) == file);
  CHECK_FALSE(error);
  loaded = presets::load(file, report);
  REQUIRE(loaded.has_value());
  CHECK(loaded->settings.choiceKey(Id::kGuides) == "off");
  CHECK(entriesIn(folder) == 1);

  CHECK(presets::remove(file, error));
  CHECK_FALSE(error);
  CHECK_FALSE(fs::exists(file));
  CHECK_FALSE(presets::remove(file, error));
  CHECK(error);
}

TEST_CASE("preset files: the list holds the folder's presets by name, ignoring case") {
  TempFolder temp;
  const fs::path& folder = temp.path();
  std::error_code error;
  for (const char* name : {"gamma", "Beta", "alpha", "Late Night"}) {
    REQUIRE_FALSE(presets::save(folder, {name, st::Settings()}, error).empty());
  }
  writeFile(folder / "Broken.json", "{");  // listed; loading it reports why it failed
  writeFile(folder / ".Hidden.json", st::encodePreset({"Hidden", st::Settings()}));
  writeFile(folder / ".DS_Store", "");
  writeFile(folder / "notes.txt", "not a preset");
  fs::create_directory(folder / "Folder.json");
  CHECK(listedNames(folder) ==
        std::vector<std::string>{"alpha", "Beta", "Broken", "gamma", "Late Night"});
}

TEST_CASE("preset files: a file that is missing, too large or not a preset does not load") {
  TempFolder temp;
  const fs::path& folder = temp.path();
  st::Report report;
  CHECK_FALSE(presets::load(folder / "Missing.json", report).has_value());
  CHECK(report.status == st::Status::kUnreadable);
  CHECK_FALSE(presets::load(folder, report).has_value());
  CHECK(report.status == st::Status::kUnreadable);

  writeFile(folder / "Huge.json", std::string(st::kMaxDocumentBytes + 1, ' '));
  CHECK_FALSE(presets::load(folder / "Huge.json", report).has_value());
  CHECK(report.status == st::Status::kTooLarge);

  writeFile(folder / "Text.json", "hello");
  CHECK_FALSE(presets::load(folder / "Text.json", report).has_value());
  CHECK(report.status == st::Status::kNotJson);

  REQUIRE(mkfifo((folder / "Pipe.json").c_str(), 0600) == 0);  // must not block
  CHECK_FALSE(presets::load(folder / "Pipe.json", report).has_value());
  CHECK(report.status == st::Status::kUnreadable);
}

TEST_CASE("preset files: a preset is named after its file, shown without control characters") {
  TempFolder temp;
  const fs::path& folder = temp.path();
  const std::string document = st::encodePreset({"Original", st::Settings()});
  const std::string long_name(150, 'x');  // longer than save() writes; Finder allows 255 bytes
  for (const std::string& name : {std::string("Renamed"), std::string("Bad\x01Name"), long_name}) {
    writeFile(folder / (name + ".json"), document);
  }

  std::vector<std::string> listed;
  for (const presets::Entry& entry : presets::list(folder)) {
    CAPTURE(entry.name);
    st::Report report;
    const std::optional<st::Preset> loaded = presets::load(entry.path, report);
    REQUIRE(loaded.has_value());
    CHECK(loaded->name == entry.name);  // the list shows the name a load gives
    listed.push_back(entry.name);
  }
  CHECK(listed == std::vector<std::string>{"BadName", "Renamed", long_name});
}

TEST_CASE("preset files: remove deletes preset files, never folders or other files") {
  TempFolder temp;
  const fs::path folder = temp.path() / "Empty.json";
  fs::create_directory(folder);
  std::error_code error;
  CHECK_FALSE(presets::remove(folder, error));
  CHECK(error);
  CHECK(fs::is_directory(folder));

  const fs::path other = temp.path() / "Notes.txt";
  writeFile(other, "keep");
  CHECK_FALSE(presets::remove(other, error));
  CHECK(error == std::errc::invalid_argument);
  CHECK(fs::exists(other));
  const fs::path bare = temp.path() / "json";
  writeFile(bare, "keep");
  CHECK_FALSE(presets::remove(bare, error));
  CHECK(fs::exists(bare));

  const fs::path upper = temp.path() / "Loud.JSON";  // the list takes any case, so remove does
  writeFile(upper, "{}");
  CHECK(presets::remove(upper, error));
  CHECK_FALSE(error);
  CHECK_FALSE(fs::exists(upper));
}

TEST_CASE("preset files: a folder that cannot be written reports the error") {
  TempFolder temp;
  writeFile(temp.path() / "file", "");
  std::error_code error;
  CHECK(presets::save(temp.path() / "file" / "Presets", {"Mix", st::Settings()}, error).empty());
  CHECK(error);

  const fs::path locked = temp.path() / "Locked";
  fs::create_directory(locked);
  REQUIRE(chmod(locked.c_str(), 0555) == 0);
  error.clear();
  CHECK(presets::save(locked, {"Mix", st::Settings()}, error).empty());
  CHECK(error);
  CHECK(entriesIn(locked) == 0);
  chmod(locked.c_str(), 0755);
}

TEST_CASE("preset file names: safe for the file system, readable, never empty") {
  CHECK(presets::fileName("Mix") == "Mix.json");
  CHECK(presets::fileName("Bus 2 · Drums 🥁") == "Bus 2 · Drums 🥁.json");
  CHECK(presets::fileName("AC/DC: Live") == "AC-DC- Live.json");
  CHECK(presets::fileName("tab\there\nnew\x7f") == "tabherenew.json");
  CHECK(presets::fileName("..hidden") == "hidden.json");
  CHECK(presets::fileName(" . . Mix  ") == "Mix.json");
  CHECK(presets::fileName("") == "Preset.json");
  CHECK(presets::fileName("...") == "Preset.json");
  CHECK(presets::fileName("\xFF\xFEok\xC3") == "ok.json");  // invalid UTF-8 is dropped
  const std::string a99(99, 'a');
  CHECK(presets::fileName(a99 + "é") == a99 + ".json");  // 101 bytes: the é is not cut in half
  CHECK(presets::fileName(std::string(300, 'b')) == std::string(100, 'b') + ".json");
}
