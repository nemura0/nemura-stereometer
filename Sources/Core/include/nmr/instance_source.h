// The app side of one plugin instance chosen as the meter's source (docs/PROMPT.md §4): its ring,
// followed across slots (an instance deactivated and activated again may claim another slot) and
// sample rates, from the registry's live list. Main thread; never on an audio thread.
#pragma once

#include <nmr/frame_ring.h>
#include <nmr/shm_transport.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace nmr::shm {

class InstanceFollower {
 public:
  enum class State {
    kWaiting,  // not sending: released, not yet activated, or its ring not yet its own
    kSending,  // listed as live; view() reads its ring
    kQuiet,    // still owns its slot but has not beaten for a second (the host stopped)
  };

  explicit InstanceFollower(uint64_t instance_id) noexcept : id_(instance_id) {}
  InstanceFollower(const InstanceFollower&) = delete;
  InstanceFollower& operator=(const InstanceFollower&) = delete;

  // Takes the latest Registry::live() list. True when the ring to read or its sample rate
  // changed: give view() and sampleRate() to the reader before the next update, which unmaps the
  // ring read until now.
  bool update(const Registry& registry, const std::vector<SlotInfo>& live);

  [[nodiscard]] State state() const noexcept { return state_; }
  // The instance's ring while sending or quiet; invalid otherwise.
  [[nodiscard]] FrameRingView view() const noexcept {
    return ring_ != nullptr ? ring_->view() : FrameRingView{};
  }
  [[nodiscard]] double sampleRate() const noexcept { return rate_; }
  [[nodiscard]] uint64_t instanceId() const noexcept { return id_; }
  // The name it last sent under (kept while it is away).
  [[nodiscard]] const std::string& name() const noexcept { return name_; }

 private:
  bool letGo();

  uint64_t id_;
  State state_ = State::kWaiting;
  std::unique_ptr<Ring> ring_;
  std::unique_ptr<Ring> retired_;  // read until the last update; unmapped at the next
  uint32_t slot_ = 0;
  double rate_ = 0;
  std::string name_;
};

}  // namespace nmr::shm
