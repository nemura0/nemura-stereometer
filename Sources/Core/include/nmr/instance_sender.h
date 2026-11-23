// A plugin instance's send to the app: a registry slot and its ring while the instance is active
// and sending is on, written from the audio thread.
//
// Control: start / stop (the host's activate / deactivate), setEnabled (the "Send to app"
// setting), rename, poll, state; none of them throws. They may come from two threads at once (an
// AU host may activate on a thread of its own while the editor polls on the main thread), so a
// mutex serializes them; the audio thread never takes it. Audio thread: write, which only copies
// and publishes (no allocation, locks or system calls). Turning sending off or stopping waits
// until a write in progress ends (a few microseconds), so the slot is never released, and its
// ring never taken over by another instance, while this one still writes to it. If the audio
// thread stays inside a write for kWriteWaitNs (a suspended host), the slot and ring are given up
// for the instance's lifetime and it reports unavailable from then on.
#pragma once

#include <nmr/monotonic_clock.h>
#include <nmr/product_config.h>
#include <nmr/shm_transport.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
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
    kUnavailable,  // turned on, but this host gives no shared memory (a sandbox), no free slot,
                   // or the slot was taken away (poll claims one again)
  };
  static constexpr uint64_t kWriteWaitNs = 2'000'000'000;

  explicit InstanceSender(std::string prefix = NMR_SHM_PREFIX);
  ~InstanceSender();
  InstanceSender(const InstanceSender&) = delete;
  InstanceSender& operator=(const InstanceSender&) = delete;

  // ---- Control (any non-audio thread) ----
  void start(double sample_rate, std::string_view name);
  void start(double sample_rate);  // under the name it has
  void stop();
  void setEnabled(bool enabled);
  [[nodiscard]] bool enabled() const;
  void rename(std::string_view name);
  // Claims a slot again after one was taken away or none was free. Cheap when nothing changed.
  void poll();
  [[nodiscard]] State state() const;
  [[nodiscard]] std::optional<uint32_t> slot() const;
  [[nodiscard]] uint64_t instanceId() const noexcept { return id_; }

  // ---- Audio thread ----
  // Stereo (a mono instance passes its channel twice). Does nothing while not sending.
  void write(const float* left, const float* right, uint32_t frames) noexcept;

 private:
  // With control_ held.
  void connect() noexcept;
  void disconnect() noexcept;

  const std::string prefix_;
  const uint64_t id_;
  const MonotonicClock clock_;
  mutable std::mutex control_;  // the control calls, never the audio thread
  bool enabled_ = true;
  bool abandoned_ = false;  // a write never ended: the slot and ring are given up
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
  std::atomic<bool> lost_{false};     // a write found the slot no longer ours
};

}  // namespace nmr
