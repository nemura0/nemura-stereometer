#include "nmr/instance_source.h"

#include <algorithm>
#include <utility>

namespace nmr::shm {

bool InstanceFollower::update(const Registry& registry, const std::vector<SlotInfo>& live) {
  retired_.reset();  // the reader moved on to view() after the last update
  const auto entry = std::find_if(live.begin(), live.end(),
                                  [this](const SlotInfo& slot) { return slot.instance_id == id_; });
  if (entry == live.end()) {
    if (ring_ != nullptr && registry.owns(slot_, id_)) {
      state_ = State::kQuiet;
      return false;
    }
    return letGo();
  }
  name_ = entry->name;
  if (ring_ != nullptr && entry->slot == slot_ && ring_->owner() == id_) {
    state_ = State::kSending;
    if (entry->sample_rate == rate_) return false;
    rate_ = entry->sample_rate;
    return true;
  }
  const bool had_ring = letGo();
  Status status = Status::kFailed;
  std::unique_ptr<Ring> ring;
  try {
    ring = Ring::open(registry, entry->slot, status);
  } catch (...) {  // out of memory: like a failed open, the caller still drops the old ring
  }
  if (ring == nullptr || ring->owner() != id_) return had_ring;  // not its ring yet: next time
  ring_ = std::move(ring);
  slot_ = entry->slot;
  rate_ = entry->sample_rate;
  state_ = State::kSending;
  return true;
}

// Retires the ring (unmapped at the next update); true if there was one.
bool InstanceFollower::letGo() {
  state_ = State::kWaiting;
  if (ring_ == nullptr) return false;
  retired_ = std::move(ring_);
  rate_ = 0;
  return true;
}

}  // namespace nmr::shm
