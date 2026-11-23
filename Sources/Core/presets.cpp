#include <nmr/presets.h>
#include <nmr/product_config.h>

#include "files.h"

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

// The original mode, Iris Bloom: solid iris dots in a strong glow, no guides but the mode's
// 0 dBFS ring, a Fast response.
Settings original() {
  Settings s;
  s.setChoice(Id::kMode, "original");
  s.setChoice(Id::kColorMode, "solid");
  s.setNumber(Id::kSolidColor, 0x8993FFFF);
  s.setChoice(Id::kGuides, "off");
  s.setNumber(Id::kGlow, 70);
  s.setNumber(Id::kTrailMs, response("Fast"));
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

settings::Settings firstRun() { return settings::applyPreset(settings::Settings{}, original()); }

fs::path directory() { return files::supportFolder("Presets"); }

std::vector<Entry> list(const fs::path& folder) { return files::list(folder, ".json"); }

std::optional<Preset> load(const fs::path& file, Report& report) {
  report = Report{};
  std::string text;
  switch (files::read(file, settings::kMaxDocumentBytes, text)) {
    case files::Read::kOk:
      break;
    case files::Read::kTooLarge:
      report.status = Status::kTooLarge;
      return std::nullopt;
    case files::Read::kUnreadable:
      report.status = Status::kUnreadable;
      return std::nullopt;
  }
  std::optional<Preset> preset = settings::decodePreset(text, report);
  if (preset) preset->name = files::shownName(file);
  return preset;
}

fs::path save(const fs::path& folder, const Preset& preset, std::error_code& error) {
  return files::write(folder, fileName(preset.name), settings::encodePreset(preset), error);
}

bool remove(const fs::path& file, std::error_code& error) {
  return files::remove(file, ".json", error);
}

std::string fileName(std::string_view name) {
  return files::fileName(name, settings::kMaxPresetNameBytes, "Preset", ".json");
}

}  // namespace nmr::presets
