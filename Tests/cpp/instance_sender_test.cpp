// A plugin instance sending to the app: claims a slot while active and sending, writes what passes
// through, releases it on stop or when sending is turned off, and reports its state.
#include <doctest/doctest.h>
#include <nmr/instance_sender.h>
#include <nmr/monotonic_clock.h>
#include <nmr/shm_transport.h>

#include <atomic>
#include <memory>
#include <thread>
#include <vector>

#include "test_prefix.h"

namespace shm = nmr::shm;
using nmr::InstanceSender;
using nmr::test::TestPrefix;
using State = InstanceSender::State;

namespace {

std::unique_ptr<shm::Registry> openRegistry(const TestPrefix& prefix) {
  shm::Status status = shm::Status::kFailed;
  auto registry = shm::Registry::open(prefix.str(), status);
  REQUIRE(registry != nullptr);
  return registry;
}

std::vector<shm::SlotInfo> live(const shm::Registry& registry) {
  return registry.live(nmr::MonotonicClock{}.nowNs());
}

std::vector<float> ramp(uint32_t frames, float start) {
  std::vector<float> samples(frames);
  for (uint32_t i = 0; i < frames; ++i) samples[i] = start + static_cast<float>(i);
  return samples;
}

}  // namespace

TEST_CASE("instance sender: off until started, then listed under its name while it sends") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  InstanceSender sender(prefix.str());
  CHECK(sender.state() == State::kOff);
  sender.start(48000, "Bass");
  REQUIRE(sender.slot().has_value());
  const auto listed = live(*registry);
  REQUIRE(listed.size() == 1);
  CHECK(listed[0].name == "Bass");
  CHECK(listed[0].instance_id == sender.instanceId());
  CHECK(listed[0].sample_rate == 48000);
  CHECK(listed[0].channels == 2);
}

TEST_CASE("instance sender: connected while the app beats, else the app is not running") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  InstanceSender sender(prefix.str());
  sender.start(48000, "Bass");
  CHECK(sender.state() == State::kNoApp);
  registry->appBeat(nmr::MonotonicClock{}.nowNs(), 4242);
  CHECK(sender.state() == State::kConnected);
  registry->appStopped(4242);
  CHECK(sender.state() == State::kNoApp);
}

TEST_CASE("instance sender: what passes through reaches the app's ring, L and R interleaved") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  InstanceSender sender(prefix.str());
  sender.start(44100, "Keys");
  const std::vector<float> left = ramp(256, 0);
  const std::vector<float> right = ramp(256, 1000);
  sender.write(left.data(), right.data(), 256);
  shm::Status status = shm::Status::kFailed;
  const auto ring = shm::Ring::open(*registry, *sender.slot(), status);
  REQUIRE(ring != nullptr);
  CHECK(ring->owner() == sender.instanceId());
  CHECK(ring->sampleRate() == 44100);
  const uint64_t written = ring->view().framesWritten();
  REQUIRE(written >= 256);
  std::vector<float> frames(512);
  CHECK(ring->view().read(written - 256, 256, frames.data()) == written - 256);
  for (uint32_t i = 0; i < 256; ++i) {
    CHECK(frames[2 * i] == left[i]);
    CHECK(frames[2 * i + 1] == right[i]);
  }
}

TEST_CASE("instance sender: stop releases the slot, and nothing is written after it") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  InstanceSender sender(prefix.str());
  sender.start(48000, "Bass");
  const uint32_t slot = *sender.slot();
  shm::Status status = shm::Status::kFailed;
  const auto ring = shm::Ring::open(*registry, slot, status);
  REQUIRE(ring != nullptr);
  sender.stop();
  CHECK(live(*registry).empty());
  CHECK_FALSE(sender.slot().has_value());
  CHECK(sender.state() == State::kOff);
  const uint64_t before = ring->view().framesWritten();
  const std::vector<float> samples = ramp(64, 0);
  sender.write(samples.data(), samples.data(), 64);
  CHECK(ring->view().framesWritten() == before);
}

TEST_CASE("instance sender: turned off while running, it releases; on again, it claims") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  InstanceSender sender(prefix.str());
  sender.start(48000, "Bass");
  sender.setEnabled(false);
  CHECK(sender.state() == State::kOff);
  CHECK(live(*registry).empty());
  sender.setEnabled(true);
  CHECK(live(*registry).size() == 1);
  sender.stop();
  sender.setEnabled(false);
  sender.start(48000, "Bass");  // started while off: nothing claimed
  CHECK(live(*registry).empty());
}

TEST_CASE("instance sender: a rename rewrites the listed name, and the id stays across starts") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  InstanceSender sender(prefix.str());
  const uint64_t id = sender.instanceId();
  sender.start(48000, "Bass");
  sender.rename("Lead");
  REQUIRE(live(*registry).size() == 1);
  CHECK(live(*registry)[0].name == "Lead");
  sender.stop();
  sender.start(96000, "Lead");
  CHECK(sender.instanceId() == id);
  REQUIRE(live(*registry).size() == 1);
  CHECK(live(*registry)[0].sample_rate == 96000);
}

TEST_CASE("instance sender: with every slot taken, sending is unavailable, not an error") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  std::vector<std::unique_ptr<InstanceSender>> senders;
  for (uint32_t i = 0; i < shm::kSlotCount; ++i) {
    senders.push_back(std::make_unique<InstanceSender>(prefix.str()));
    senders.back()->start(48000, "Track");
    CHECK(senders.back()->slot().has_value());
  }
  InstanceSender extra(prefix.str());
  extra.start(48000, "One too many");
  CHECK(extra.state() == State::kUnavailable);
  const std::vector<float> samples = ramp(64, 0);
  extra.write(samples.data(), samples.data(), 64);  // writes nothing, and does not crash
  senders.front()->stop();
  extra.setEnabled(false);
  extra.setEnabled(true);  // tries again
  CHECK(extra.slot().has_value());
}

TEST_CASE("instance sender: a registry it may not open is unavailable") {
  InstanceSender sender("/nmr.t-too-long-a-prefix-for-shm");  // names over 31 bytes fail
  sender.start(48000, "Bass");
  CHECK(sender.state() == State::kUnavailable);
  CHECK_FALSE(sender.slot().has_value());
}

TEST_CASE("instance sender: turning it off while the audio thread writes never tears a write") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  InstanceSender sender(prefix.str());
  sender.start(48000, "Bass");
  std::atomic<bool> running{true};
  const std::vector<float> samples = ramp(256, 0);
  std::thread audio([&] {
    while (running.load(std::memory_order_relaxed)) {
      sender.write(samples.data(), samples.data(), 256);
    }
  });
  for (int i = 0; i < 200; ++i) {
    sender.setEnabled(false);
    sender.setEnabled(true);
  }
  running = false;
  audio.join();
  CHECK(live(*registry).size() == 1);
}
