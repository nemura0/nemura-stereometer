// The built plugin sending to the app: listed in the registry while active and sending, under
// its track's name, its own source name or "Stereometer N", with the audio that passes through.
#include <doctest/doctest.h>
#include <nmr/monotonic_clock.h>
#include <nmr/presets.h>
#include <nmr/product_config.h>
#include <nmr/settings_json.h>
#include <nmr/shm_transport.h>

#include <cstring>
#include <memory>
#include <optional>
#include <random>
#include <string>
#include <vector>

#include "clap_host.h"

using nmr::test::Channels;
using nmr::test::ClapInstance;
using nmr::test::ClapLibrary;
namespace settings = nmr::settings;
namespace shm = nmr::shm;

namespace {

std::unique_ptr<shm::Registry> openRegistry() {
  shm::Status status = shm::Status::kFailed;
  auto registry = shm::Registry::open(ClapLibrary::shared().sendPrefix(), status);
  REQUIRE(registry != nullptr);
  return registry;
}

std::vector<shm::SlotInfo> live(const shm::Registry& registry) {
  return registry.live(nmr::MonotonicClock{}.nowNs());
}

std::optional<shm::SlotInfo> listed(const shm::Registry& registry, const std::string& name) {
  for (const shm::SlotInfo& info : live(registry)) {
    if (info.name == name) return info;
  }
  return std::nullopt;
}

Channels noise(uint32_t channels, uint32_t frames, uint32_t seed) {
  std::mt19937 random(seed);
  std::uniform_real_distribution<float> sample(-1, 1);
  Channels audio(channels, std::vector<float>(frames));
  for (auto& channel : audio) {
    for (float& value : channel) value = sample(random);
  }
  return audio;
}

void run(ClapInstance& instance, const Channels& signal) {
  Channels in = signal;
  Channels out(signal.size(), std::vector<float>(signal[0].size()));
  REQUIRE(instance.process(in, out) == CLAP_PROCESS_CONTINUE);
}

// The newest `frames` frames of the slot's ring, interleaved.
std::vector<float> newest(const shm::Registry& registry, uint32_t slot, uint32_t frames) {
  shm::Status status = shm::Status::kFailed;
  const auto ring = shm::Ring::open(registry, slot, status);
  REQUIRE(ring != nullptr);
  const uint64_t written = ring->view().framesWritten();
  REQUIRE(written >= frames);
  std::vector<float> out(size_t{frames} * 2);
  REQUIRE(ring->view().read(written - frames, frames, out.data()) == written - frames);
  return out;
}

std::string stateWith(bool send, const std::string& source_name) {
  settings::Settings changed = nmr::presets::firstRun();
  changed.setNumber(settings::Id::kSendToApp, send ? 1 : 0);
  changed.setText(settings::Id::kSourceName, source_name);
  return settings::encodeState(changed);
}

}  // namespace

TEST_CASE("send: an active instance is listed and sends what passes through, unchanged") {
  const auto registry = openRegistry();
  ClapInstance instance;
  REQUIRE(instance.valid());
  CHECK(live(*registry).empty());  // not before it is active
  REQUIRE(instance.activate(44100));
  const auto slots = live(*registry);
  REQUIRE(slots.size() == 1);
  CHECK(slots[0].name.rfind(NMR_PRODUCT_SHORT " ", 0) == 0);  // "Stereometer N"
  CHECK(slots[0].sample_rate == 44100);
  const Channels signal = noise(2, 256, 3);
  run(instance, signal);
  const std::vector<float> frames = newest(*registry, slots[0].slot, 256);
  for (uint32_t i = 0; i < 256; ++i) {
    CHECK(std::memcmp(&frames[2 * i], &signal[0][i], sizeof(float)) == 0);
    CHECK(std::memcmp(&frames[2 * i + 1], &signal[1][i], sizeof(float)) == 0);
  }
  instance.deactivate();
  CHECK(live(*registry).empty());
}

TEST_CASE("send: a mono track sends its channel as L and R") {
  const auto registry = openRegistry();
  ClapInstance instance("Vox");
  REQUIRE(instance.valid());
  const auto* ports = instance.extension<clap_plugin_configurable_audio_ports_t>(
      CLAP_EXT_CONFIGURABLE_AUDIO_PORTS);
  REQUIRE(ports != nullptr);
  const clap_audio_port_configuration_request_t mono[] = {
      {true, 0, 1, CLAP_PORT_MONO, nullptr}, {false, 0, 1, CLAP_PORT_MONO, nullptr}};
  REQUIRE(ports->apply_configuration(instance.plugin(), mono, 2));
  REQUIRE(instance.activate());
  const Channels signal = noise(1, 128, 4);
  run(instance, signal);
  const auto info = listed(*registry, "Vox");
  REQUIRE(info.has_value());
  CHECK(info->channels == 2);
  const std::vector<float> frames = newest(*registry, info->slot, 128);
  for (uint32_t i = 0; i < 128; ++i) {
    CHECK(frames[2 * i] == signal[0][i]);
    CHECK(frames[2 * i + 1] == signal[0][i]);
  }
}

TEST_CASE("send: named after its track, following a rename") {
  const auto registry = openRegistry();
  ClapInstance instance("Bass");
  REQUIRE(instance.valid());
  REQUIRE(instance.activate());
  CHECK(listed(*registry, "Bass").has_value());
  instance.renameTrack("Lead");
  CHECK(listed(*registry, "Lead").has_value());
  CHECK_FALSE(listed(*registry, "Bass").has_value());
}

TEST_CASE("send: a source name in its settings wins over the track's") {
  const auto registry = openRegistry();
  ClapInstance instance("Bass");
  REQUIRE(instance.valid());
  REQUIRE(instance.load(stateWith(true, "Keys")));
  REQUIRE(instance.activate());
  CHECK(listed(*registry, "Keys").has_value());
  REQUIRE(instance.load(stateWith(true, "")));  // cleared: the track's name again
  CHECK(listed(*registry, "Bass").has_value());
}

TEST_CASE("send: turned off in its settings it leaves the list; on again it is back") {
  const auto registry = openRegistry();
  ClapInstance instance("Drums");
  REQUIRE(instance.valid());
  REQUIRE(instance.activate());
  REQUIRE(listed(*registry, "Drums").has_value());
  REQUIRE(instance.load(stateWith(false, "")));
  CHECK(live(*registry).empty());
  run(instance, noise(2, 64, 5));  // processing while off sends nothing, and is fine
  REQUIRE(instance.load(stateWith(true, "")));
  CHECK(listed(*registry, "Drums").has_value());
}

TEST_CASE("send: a project saved with sending off opens without sending") {
  const auto registry = openRegistry();
  ClapInstance instance("Drums");
  REQUIRE(instance.valid());
  REQUIRE(instance.load(stateWith(false, "")));
  REQUIRE(instance.activate());
  CHECK(live(*registry).empty());
}

TEST_CASE("send: ten instances send at once, each in its own slot, each with its own name") {
  const auto registry = openRegistry();
  std::vector<std::unique_ptr<ClapInstance>> instances;
  for (int i = 0; i < 10; ++i) {
    instances.push_back(std::make_unique<ClapInstance>());
    REQUIRE(instances.back()->valid());
    REQUIRE(instances.back()->activate());
    run(*instances.back(), noise(2, 64, 10 + i));
  }
  const auto slots = live(*registry);
  CHECK(slots.size() == 10);
  for (size_t i = 0; i < slots.size(); ++i) {
    for (size_t j = 0; j < i; ++j) {
      CHECK(slots[i].slot != slots[j].slot);
      CHECK(slots[i].name != slots[j].name);
    }
  }
  instances.clear();
  CHECK(live(*registry).empty());
}
