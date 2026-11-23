#include <nmr/instance_sender.h>

#include <thread>
#include <utility>

namespace nmr {

namespace {
constexpr uint32_t kSentChannels = 2;  // the ring is always stereo; mono sends L = R
}  // namespace

InstanceSender::InstanceSender(std::string prefix)
    : prefix_(std::move(prefix)), id_(shm::newInstanceId()) {}

InstanceSender::~InstanceSender() {
  const std::lock_guard lock(control_);
  disconnect();
}

void InstanceSender::start(double sample_rate, std::string_view name) {
  const std::lock_guard lock(control_);
  try {
    name_ = name;
  } catch (...) {  // out of memory: keep the old name
  }
  if (running_) disconnect();  // started again without a stop: claim anew at this rate
  sample_rate_ = sample_rate;
  running_ = true;
  connect();
}

void InstanceSender::start(double sample_rate) {
  const std::lock_guard lock(control_);
  if (running_) disconnect();
  sample_rate_ = sample_rate;
  running_ = true;
  connect();
}

void InstanceSender::stop() {
  const std::lock_guard lock(control_);
  running_ = false;
  disconnect();
}

void InstanceSender::setEnabled(bool enabled) {
  const std::lock_guard lock(control_);
  if (enabled == enabled_) return;
  enabled_ = enabled;
  if (enabled_) {
    connect();
  } else {
    disconnect();
  }
}

bool InstanceSender::enabled() const {
  const std::lock_guard lock(control_);
  return enabled_;
}

void InstanceSender::rename(std::string_view name) {
  const std::lock_guard lock(control_);
  try {
    name_ = name;
  } catch (...) {
    return;
  }
  if (registry_ != nullptr && slot_) {
    registry_->describe(*slot_, id_, sample_rate_, kSentChannels, name_);
  }
}

// Cheap when nothing changed: claims again only when sending should run and has no slot, or the
// slot was taken away.
void InstanceSender::poll() {
  const std::lock_guard lock(control_);
  if (!enabled_ || !running_ || abandoned_) return;
  if (slot_ && !lost_.load(std::memory_order_acquire)) return;
  if (slot_) disconnect();
  connect();
}

InstanceSender::State InstanceSender::state() const {
  const std::lock_guard lock(control_);
  if (!enabled_ || !running_) return State::kOff;
  if (abandoned_ || unavailable_ || !slot_ || lost_.load(std::memory_order_acquire)) {
    return State::kUnavailable;
  }
  return registry_->appAlive(clock_.nowNs()) ? State::kConnected : State::kNoApp;
}

std::optional<uint32_t> InstanceSender::slot() const {
  const std::lock_guard lock(control_);
  return slot_;
}

// Control, with control_ held. Opens the registry once, then claims a slot and maps its ring; any
// failure leaves the sender unavailable (tried again on the next start, poll, or when turned on).
void InstanceSender::connect() noexcept {
  // After an abandoned write the audio thread may still be inside it, reading audio_ring_.
  if (!enabled_ || !running_ || slot_ || abandoned_) return;
  unavailable_ = true;
  std::optional<uint32_t> slot;
  try {
    shm::Status status = shm::Status::kFailed;
    if (registry_ == nullptr) registry_ = shm::Registry::open(prefix_, status);
    if (registry_ == nullptr) return;
    slot = registry_->claim(id_, sample_rate_, kSentChannels, name_, clock_, status);
    if (!slot) return;
    ring_ = shm::Ring::create(*registry_, *slot, id_, sample_rate_, status);
  } catch (...) {  // out of memory
    ring_.reset();
  }
  if (ring_ == nullptr) {
    if (slot) registry_->release(*slot, id_);
    return;
  }
  slot_ = slot;
  unavailable_ = false;
  lost_.store(false, std::memory_order_relaxed);
  audio_slot_ = *slot;
  audio_ring_ = ring_->view();
  sending_.store(true, std::memory_order_seq_cst);  // publishes the fields above
}

// Control, with control_ held. After sending_ is cleared, a write that began before it may still
// be running; one that begins after it sees it cleared and touches nothing. Wait out the first
// kind, then release.
void InstanceSender::disconnect() noexcept {
  if (abandoned_) return;
  sending_.store(false, std::memory_order_seq_cst);
  const uint64_t deadline = clock_.nowNs() + kWriteWaitNs;
  while (writing_.load(std::memory_order_seq_cst)) {
    if (clock_.nowNs() > deadline) {
      // The audio thread is stuck inside a write: keep the slot claimed and the ring mapped (both
      // are given up for this instance's lifetime), so no other instance gets a ring it writes to.
      (void)ring_.release();
      slot_.reset();
      abandoned_ = true;
      return;
    }
    std::this_thread::yield();
  }
  if (registry_ != nullptr && slot_) registry_->release(*slot_, id_);
  slot_.reset();
  ring_.reset();
  audio_ring_ = FrameRingView{};
  unavailable_ = false;
}

void InstanceSender::write(const float* left, const float* right, uint32_t frames) noexcept {
  writing_.store(true, std::memory_order_seq_cst);
  if (sending_.load(std::memory_order_seq_cst)) {
    if (registry_->beat(audio_slot_, id_, clock_.nowNs())) {
      audio_ring_.writeSplit(left, right, frames);
    } else {
      lost_.store(true, std::memory_order_release);  // the main thread reports it and re-claims
    }
  }
  writing_.store(false, std::memory_order_release);
}

}  // namespace nmr
