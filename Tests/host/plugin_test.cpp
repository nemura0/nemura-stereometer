// Tests of the built CLAP plugin through a test host: bit-exact pass-through (the null test) in
// stereo and mono, the layouts it accepts, and its versioned settings state.
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>

#include <nmr/presets.h>
#include <nmr/settings_json.h>

#include <cstring>
#include <random>
#include <string>

#include "clap_host.h"

using nmr::test::Channels;
using nmr::test::ClapInstance;
namespace settings = nmr::settings;

namespace {

// Random bit patterns: every float, NaNs with payloads, infinities, denormals and -0 included.
Channels noise(uint32_t channels, uint32_t frames, uint32_t seed) {
  std::mt19937 random(seed);
  Channels audio(channels, std::vector<float>(frames));
  for (auto& channel : audio) {
    for (float& sample : channel) {
      const uint32_t bits = random();
      std::memcpy(&sample, &bits, sizeof(sample));
    }
  }
  return audio;
}

bool sameBits(const Channels& a, const Channels& b) {
  if (a.size() != b.size()) return false;
  for (size_t c = 0; c < a.size(); ++c) {
    if (a[c].size() != b[c].size()) return false;
    if (std::memcmp(a[c].data(), b[c].data(), a[c].size() * sizeof(float)) != 0) return false;
  }
  return true;
}

clap_audio_port_configuration_request_t request(bool input, uint32_t channels) {
  return {input, 0, channels, channels == 1 ? CLAP_PORT_MONO : CLAP_PORT_STEREO, nullptr};
}

bool configure(ClapInstance& instance, uint32_t in, uint32_t out) {
  const auto* ports = instance.extension<clap_plugin_configurable_audio_ports_t>(
      CLAP_EXT_CONFIGURABLE_AUDIO_PORTS);
  if (ports == nullptr) return false;
  const clap_audio_port_configuration_request_t requests[] = {request(true, in),
                                                              request(false, out)};
  if (!ports->can_apply_configuration(instance.plugin(), requests, 2)) return false;
  return ports->apply_configuration(instance.plugin(), requests, 2);
}

clap_audio_port_info_t port(const ClapInstance& instance, bool input) {
  const auto* ports = instance.extension<clap_plugin_audio_ports_t>(CLAP_EXT_AUDIO_PORTS);
  clap_audio_port_info_t info{};
  REQUIRE(ports != nullptr);
  REQUIRE(ports->count(instance.plugin(), input) == 1);
  REQUIRE(ports->get(instance.plugin(), 0, input, &info));
  return info;
}

// Every block size and both buffer arrangements give back exactly the input.
void checkPassThrough(ClapInstance& instance, uint32_t channels) {
  uint32_t seed = 1;
  for (const uint32_t frames : {1u, 7u, 64u, 256u, 1000u, 4096u}) {
    CAPTURE(frames);
    const Channels signal = noise(channels, frames, seed++);
    Channels in = signal;
    Channels out(channels, std::vector<float>(frames, 0.5f));
    CHECK(instance.process(in, out) == CLAP_PROCESS_CONTINUE);
    CHECK(sameBits(out, signal));
    CHECK(sameBits(in, signal));  // the input is left alone
    Channels shared = signal;
    Channels unused;
    CHECK(instance.process(shared, unused, true) == CLAP_PROCESS_CONTINUE);
    CHECK(sameBits(shared, signal));
  }
}

// A state document with every plugin-relevant kind of entry changed from its default.
settings::Settings changedSettings() {
  settings::Settings changed;
  CHECK(changed.setChoice(settings::Id::kMode, "lissajous") == settings::Change::kSet);
  CHECK(changed.setNumber(settings::Id::kGainDb, 6) == settings::Change::kSet);
  CHECK(changed.setNumber(settings::Id::kSendToApp, 0) == settings::Change::kSet);
  CHECK(changed.setText(settings::Id::kSourceName, "Bass") == settings::Change::kSet);
  return changed;
}

settings::Settings savedSettings(const ClapInstance& instance) {
  std::string state;
  REQUIRE(instance.save(state));
  settings::Report report;
  const settings::Settings saved = settings::decodeState(state, report);
  REQUIRE(report.status == settings::Status::kOk);
  CHECK(report.version == settings::kFormatVersion);
  return saved;
}

}  // namespace

TEST_CASE("plugin: the library loads and creates an instance") {
  INFO(nmr::test::ClapLibrary::shared().error());
  const ClapInstance instance;
  REQUIRE(instance.valid());
}

TEST_CASE("plugin: stereo passes through bit-exact (null test)") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  CHECK(port(instance, true).channel_count == 2);
  CHECK(port(instance, false).channel_count == 2);
  REQUIRE(instance.activate());
  checkPassThrough(instance, 2);
}

TEST_CASE("plugin: a mono track passes through bit-exact") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  REQUIRE(configure(instance, 1, 1));
  for (const bool input : {true, false}) {
    const clap_audio_port_info_t info = port(instance, input);
    CHECK(info.channel_count == 1);
    CHECK(std::strcmp(info.port_type, CLAP_PORT_MONO) == 0);
  }
  REQUIRE(instance.activate());
  checkPassThrough(instance, 1);
}

TEST_CASE("plugin: mono back to stereo") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  REQUIRE(configure(instance, 1, 1));
  REQUIRE(configure(instance, 2, 2));
  CHECK(port(instance, true).channel_count == 2);
  REQUIRE(instance.activate());
  checkPassThrough(instance, 2);
}

TEST_CASE("plugin: only mono and stereo, the same on both sides, and only while inactive") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  CHECK_FALSE(configure(instance, 6, 6));
  CHECK_FALSE(configure(instance, 1, 2));
  CHECK_FALSE(configure(instance, 2, 1));
  CHECK(port(instance, true).channel_count == 2);  // unchanged
  REQUIRE(instance.activate());
  CHECK_FALSE(configure(instance, 1, 1));
  CHECK(port(instance, true).channel_count == 2);
}

TEST_CASE("plugin: a request names port 0 with a matching type, or no type at all") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  const auto* ports = instance.extension<clap_plugin_configurable_audio_ports_t>(
      CLAP_EXT_CONFIGURABLE_AUDIO_PORTS);
  REQUIRE(ports != nullptr);
  const auto check = [&](clap_audio_port_configuration_request_t in,
                         clap_audio_port_configuration_request_t out) {
    const clap_audio_port_configuration_request_t requests[] = {in, out};
    return ports->can_apply_configuration(instance.plugin(), requests, 2);
  };
  CHECK(check({true, 0, 1, nullptr, nullptr}, {false, 0, 1, nullptr, nullptr}));
  CHECK_FALSE(check({true, 0, 1, CLAP_PORT_STEREO, nullptr}, request(false, 1)));
  CHECK_FALSE(check({true, 1, 1, CLAP_PORT_MONO, nullptr}, request(false, 1)));
  CHECK(ports->can_apply_configuration(instance.plugin(), nullptr, 0));  // nothing changes
  CHECK_FALSE(ports->can_apply_configuration(instance.plugin(), nullptr, 2));
}

TEST_CASE("plugin: the layout can change again once deactivated") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  REQUIRE(instance.activate());
  instance.deactivate();
  REQUIRE(configure(instance, 1, 1));
  REQUIRE(instance.activate());
  checkPassThrough(instance, 1);
}

TEST_CASE("plugin: an empty block is fine") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  REQUIRE(instance.activate());
  Channels in(2);
  Channels out(2);
  CHECK(instance.process(in, out) == CLAP_PROCESS_CONTINUE);
}

TEST_CASE("plugin: a constant input channel comes out as every frame of that value") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  REQUIRE(instance.activate());
  Channels in = noise(2, 256, 7);
  const float constant = in[1][0];
  Channels out(2, std::vector<float>(256, 0));
  CHECK(instance.process(in, out, false, 0b10) == CLAP_PROCESS_CONTINUE);
  CHECK(std::memcmp(out[0].data(), in[0].data(), 256 * sizeof(float)) == 0);
  for (const float sample : out[1]) CHECK(std::memcmp(&sample, &constant, sizeof(float)) == 0);
  Channels shared = in;  // in place: the constant channel is filled out where it lies
  Channels unused;
  CHECK(instance.process(shared, unused, true, 0b10) == CLAP_PROCESS_CONTINUE);
  CHECK(std::memcmp(shared[0].data(), in[0].data(), 256 * sizeof(float)) == 0);
  for (const float sample : shared[1]) CHECK(std::memcmp(&sample, &constant, sizeof(float)) == 0);
}

TEST_CASE("plugin: a new instance saves its settings as a versioned settings document") {
  const ClapInstance instance;
  REQUIRE(instance.valid());
  CHECK(savedSettings(instance) == nmr::presets::firstRun());
}

TEST_CASE("plugin: the state it loads is the state it saves, in any chunk size") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  const settings::Settings changed = changedSettings();
  REQUIRE(instance.load(settings::encodeState(changed), 3));
  CHECK(savedSettings(instance) == changed);
  std::string small_chunks;
  REQUIRE(instance.save(small_chunks, 5));
  std::string whole;
  REQUIRE(instance.save(whole));
  CHECK(small_chunks == whole);

  ClapInstance restored;  // a project reopened
  REQUIRE(restored.valid());
  REQUIRE(restored.load(whole));
  CHECK(savedSettings(restored) == changed);
}

TEST_CASE("plugin: an unreadable state is refused and the settings stay as they were") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  REQUIRE(instance.load(settings::encodeState(changedSettings())));
  const std::string too_large(settings::kMaxDocumentBytes + 1, ' ');
  for (const std::string& bad : {std::string(), std::string("not json"), std::string("\x01\xff"),
                                 std::string(R"({"version":1})"), std::string("[1,2]"),
                                 too_large}) {
    CAPTURE(bad.substr(0, 16));
    CHECK_FALSE(instance.load(bad));
    CHECK(savedSettings(instance) == changedSettings());
  }
}

TEST_CASE("plugin: a state from the first builds loads as the first-run settings") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  REQUIRE(instance.load(settings::encodeState(changedSettings())));
  CHECK(instance.load(R"({"format":"nemura-stereometer-state","version":1})"));
  CHECK(savedSettings(instance) == nmr::presets::firstRun());
  // Only that exact document: one that merely mentions it is refused.
  CHECK_FALSE(instance.load(R"({"format":"nemura-stereometer-state","version":2})"));
}
