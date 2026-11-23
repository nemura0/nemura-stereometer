// A plugin instance's send to the app: a registry slot and its ring while the instance is active
// and sending is on, written from the audio thread.
//
// Main thread: start / stop (the host's activate / deactivate), setEnabled (the "Send to app"
// setting), rename, state. Audio thread: write, which only copies and publishes (no allocation,
// locks or system calls). Turning sending off or stopping waits until a write in progress ends
// (a few microseconds), so the slot is never released, and its ring never taken over by another
// instance, while this one still writes to it.
#pragma once

#include <nmr/monotonic_clock.h>
#include <nmr/product_config.h>
#include <nmr/shm_transport.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

namespace nmr {

class InstanceSender {
 public:
  enum class State : uint8_t {
    kOff,          // not sending: turned off, or not active
    kConnected,    // sending, and the app is running
    kNoApp,        // sending, but the app is not running
    kUnavailable,  // turned on, but this host gives no shared memory (a sandbox), or no free slot
  };

  explicit InstanceSender(std::string prefix = NMR_SHM_PREFIX);
  ~InstanceSender();
  InstanceSender(const InstanceSender&) = delete;
  InstanceSender& operator=(const InstanceSender&) = delete;

  // ---- Main thread ----
  void start(double sample_rate, std::string_view name);
  void stop();
  void setEnabled(bool enabled);
  [[nodiscard]] bool enabled() const noexcept { return enabled_; }
  void rename(std::string_view name);
  [[nodiscard]] State state() const;
  [[nodiscard]] std::optional<uint32_t> slot() const noexcept { return slot_; }
  [[nodiscard]] uint64_t instanceId() const noexcept { return id_; }
  // The registry, once opened (to read other instances' names); nullptr before or if it failed.
  [[nodiscard]] const shm::Registry* registry() const noexcept { return registry_.get(); }

  // ---- Audio thread ----
  // Stereo (a mono instance passes its channel twice). Does nothing while not sending.
  void write(const float* left, const float* right, uint32_t frames) noexcept;

 private:
  void connect();
  void disconnect();

  const std::string prefix_;
  const uint64_t id_;
  const MonotonicClock clock_;
  bool enabled_ = true;
  bool running_ = false;
  bool unavailable_ = false;
  double sample_rate_ = 0;
  std::string name_;
  std::unique_ptr<shm::Registry> registry_;
  std::unique_ptr<shm::Ring> ring_;
  std::optional<uint32_t> slot_;

  // What the audio thread reads, published by sending_ (written while it is false).
  uint32_t audio_slot_ = 0;
  FrameRingView audio_ring_;
  std::atomic<bool> sending_{false};
  std::atomic<bool> writing_{false};  // the audio thread is inside write()
};

}  // namespace nmr
