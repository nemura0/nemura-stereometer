#include <nmr/instance_sender.h>

#include <thread>
#include <utility>

namespace nmr {

namespace {
constexpr uint32_t kSentChannels = 2;  // the ring is always stereo; mono sends L = R
}  // namespace

InstanceSender::InstanceSender(std::string prefix)
    : prefix_(std::move(prefix)), id_(shm::newInstanceId()) {}

InstanceSender::~InstanceSender() { disconnect(); }

void InstanceSender::start(double sample_rate, std::string_view name) {
  sample_rate_ = sample_rate;
  name_ = name;
  running_ = true;
  connect();
}

void InstanceSender::stop() {
  running_ = false;
  disconnect();
}

void InstanceSender::setEnabled(bool enabled) {
  if (enabled == enabled_) return;
  enabled_ = enabled;
  if (enabled_) {
    connect();
  } else {
    disconnect();
  }
}

void InstanceSender::rename(std::string_view name) {
  name_ = name;
  if (registry_ != nullptr && slot_) {
    registry_->describe(*slot_, id_, sample_rate_, kSentChannels, name_);
  }
}

InstanceSender::State InstanceSender::state() const {
  if (!enabled_ || !running_) return State::kOff;
  if (unavailable_ || !slot_) return State::kUnavailable;
  return registry_->appAlive(clock_.nowNs()) ? State::kConnected : State::kNoApp;
}

// Main thread. Opens the registry once, then claims a slot and maps its ring; any failure leaves
// the sender unavailable (tried again on the next start or when turned on again).
void InstanceSender::connect() {
  if (!enabled_ || !running_ || slot_) return;
  unavailable_ = true;
  shm::Status status = shm::Status::kFailed;
  if (registry_ == nullptr) registry_ = shm::Registry::open(prefix_, status);
  if (registry_ == nullptr) return;
  const std::optional<uint32_t> slot =
      registry_->claim(id_, sample_rate_, kSentChannels, name_, clock_, status);
  if (!slot) return;
  std::unique_ptr<shm::Ring> ring = shm::Ring::create(*registry_, *slot, id_, sample_rate_, status);
  if (ring == nullptr) {
    registry_->release(*slot, id_);
    return;
  }
  ring_ = std::move(ring);
  slot_ = slot;
  unavailable_ = false;
  audio_slot_ = *slot;
  audio_ring_ = ring_->view();
  sending_.store(true, std::memory_order_seq_cst);  // publishes the two fields above
}

// Main thread. After sending_ is cleared, a write that began before it may still be running; one
// that begins after it sees it cleared and touches nothing. Wait out the first kind, then release.
void InstanceSender::disconnect() {
  sending_.store(false, std::memory_order_seq_cst);
  while (writing_.load(std::memory_order_seq_cst)) std::this_thread::yield();
  if (registry_ != nullptr && slot_) registry_->release(*slot_, id_);
  slot_.reset();
  ring_.reset();
  audio_ring_ = FrameRingView{};
  unavailable_ = false;
}

void InstanceSender::write(const float* left, const float* right, uint32_t frames) noexcept {
  writing_.store(true, std::memory_order_seq_cst);
  if (sending_.load(std::memory_order_seq_cst) &&
      registry_->beat(audio_slot_, id_, clock_.nowNs())) {
    audio_ring_.writeSplit(left, right, frames);
  }
  writing_.store(false, std::memory_order_release);
}

}  // namespace nmr
