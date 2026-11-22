// The app following one plugin instance: its ring, across releases, new slots and rates.
#include <doctest/doctest.h>
#include <nmr/instance_source.h>
#include <nmr/monotonic_clock.h>
#include <nmr/shm_transport.h>

#include <cstdint>
#include <memory>
#include <vector>

#include "test_prefix.h"

namespace shm = nmr::shm;
using nmr::test::TestPrefix;
using State = shm::InstanceFollower::State;

namespace {

constexpr uint64_t kSecondNs = 1'000'000'000;

struct Instance {
  uint64_t id = shm::newInstanceId();
  uint32_t slot = 0;
  std::unique_ptr<shm::Ring> ring;
};

std::unique_ptr<shm::Registry> openRegistry(const TestPrefix& prefix) {
  shm::Status status = shm::Status::kFailed;
  auto registry = shm::Registry::open(prefix.str(), status);
  REQUIRE(registry != nullptr);
  return registry;
}

Instance claim(shm::Registry& registry, double rate, const char* name,
               const nmr::MonotonicClock& clock) {
  Instance instance;
  shm::Status status = shm::Status::kFailed;
  const auto slot = registry.claim(instance.id, rate, 2, name, clock, status);
  REQUIRE(slot.has_value());
  instance.slot = *slot;
  instance.ring = shm::Ring::create(registry, *slot, instance.id, rate, status);
  REQUIRE(instance.ring != nullptr);
  return instance;
}

}  // namespace

TEST_CASE("instance source: waits for an instance that is not sending") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  shm::InstanceFollower follower(shm::newInstanceId());
  CHECK_FALSE(follower.update(*registry, registry->live(clock.nowNs())));
  CHECK(follower.state() == State::kWaiting);
  CHECK_FALSE(follower.view().valid());
}

TEST_CASE("instance source: reads the instance's ring while it sends") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  Instance bass = claim(*registry, 48000, "Bass", clock);
  shm::InstanceFollower follower(bass.id);
  CHECK(follower.update(*registry, registry->live(clock.nowNs())));
  CHECK(follower.state() == State::kSending);
  CHECK(follower.name() == "Bass");
  CHECK(follower.sampleRate() == 48000);
  REQUIRE(follower.view().valid());

  const std::vector<float> frames = {0.25f, -0.5f, 0.75f, -1.0f};
  bass.ring->view().write(frames.data(), 2);
  std::vector<float> read(4);
  CHECK(follower.view().framesWritten() == bass.ring->view().framesWritten());
  CHECK(follower.view().read(follower.view().framesWritten() - 2, 2, read.data()) ==
        follower.view().framesWritten() - 2);
  CHECK(read == frames);
  // Nothing changed: the same ring, nothing for the reader to do.
  CHECK_FALSE(follower.update(*registry, registry->live(clock.nowNs())));
}

TEST_CASE("instance source: a quiet instance keeps its ring, a released one is let go") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  Instance bass = claim(*registry, 48000, "Bass", clock);
  shm::InstanceFollower follower(bass.id);
  REQUIRE(follower.update(*registry, registry->live(clock.nowNs())));

  // The host stopped processing: no heartbeat for over a second, the slot still owned.
  CHECK_FALSE(follower.update(*registry, registry->live(clock.nowNs() + 3 * kSecondNs)));
  CHECK(follower.state() == State::kQuiet);
  CHECK(follower.view().valid());

  registry->release(bass.slot, bass.id);
  CHECK(follower.update(*registry, registry->live(clock.nowNs())));
  CHECK(follower.state() == State::kWaiting);
  CHECK_FALSE(follower.view().valid());
  CHECK(follower.name() == "Bass");  // still named, for the picker
}

TEST_CASE("instance source: follows the instance to a new slot and a new rate") {
  const TestPrefix prefix;
  const auto registry = openRegistry(prefix);
  const nmr::MonotonicClock clock;
  Instance bass = claim(*registry, 48000, "Bass", clock);
  shm::InstanceFollower follower(bass.id);
  REQUIRE(follower.update(*registry, registry->live(clock.nowNs())));

  // Deactivated and activated again at 96 kHz while another instance took its old slot.
  registry->release(bass.slot, bass.id);
  bass.ring.reset();
  Instance drums = claim(*registry, 48000, "Drums", clock);
  CHECK(drums.slot == bass.slot);
  shm::Status status = shm::Status::kFailed;
  const auto slot = registry->claim(bass.id, 96000, 2, "Bass", clock, status);
  REQUIRE(slot.has_value());
  CHECK(*slot != drums.slot);
  bass.ring = shm::Ring::create(*registry, *slot, bass.id, 96000, status);
  REQUIRE(bass.ring != nullptr);

  const nmr::FrameRingView before = follower.view();
  const uint64_t written_before = before.framesWritten();
  CHECK(follower.update(*registry, registry->live(clock.nowNs())));
  // The old ring stays mapped until the next update, so a reader still on it is safe.
  CHECK(before.framesWritten() == written_before);
  CHECK(follower.state() == State::kSending);
  CHECK(follower.sampleRate() == 96000);
  const std::vector<float> frames = {0.5f, 0.5f};
  bass.ring->view().write(frames.data(), 1);
  CHECK(follower.view().framesWritten() == bass.ring->view().framesWritten());

  // A new rate in the same slot is a change for the reader too.
  REQUIRE(registry->describe(*slot, bass.id, 44100, 2, "Bass"));
  bass.ring->setSampleRate(44100);
  CHECK(follower.update(*registry, registry->live(clock.nowNs())));
  CHECK(follower.sampleRate() == 44100);
}
