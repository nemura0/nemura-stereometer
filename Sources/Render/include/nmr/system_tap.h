// System-output capture through a Core Audio process tap (macOS 14.2+; used by the app only).
//
// A private, unmuted, global stereo tap (every process) is placed in a private aggregate device
// whose main sub-device is the current default output device, which provides the clock. The
// aggregate's IO proc is a plain C++ function registered with AudioDeviceCreateIOProcID, so the
// HAL calls it on its real-time IO thread with no dispatch queue in between. It only copies the
// tap's frames into a FrameRingView and bumps relaxed counters; nothing else runs there.
//
// start() and stop() run on one non-real-time thread and may block: creating the tap waits while
// macOS shows the audio-capture permission prompt. A denied permission is not an error: the tap
// then delivers silent buffers.
#pragma once

#include <CoreAudio/AudioHardware.h>
#include <nmr/frame_ring.h>

#include <atomic>
#include <cstddef>
#include <cstdint>

#include <sys/types.h>

namespace nmr {

struct TapFormat {
  double sample_rate = 0;
  uint32_t channels = 0;
  bool interleaved = true;
};

// Turns off the first `count` input streams of `device` for `proc` (call before
// AudioDeviceStart). The capture aggregate lists its clock device's own inputs before the tap;
// reading them would show the app as using the microphone. Non-real-time thread only.
OSStatus turnOffInputStreams(AudioObjectID device, AudioDeviceIOProcID proc,
                             uint32_t count) noexcept;

// Whether any process but `except` (a pid; -1 leaves none out) runs audio output on `device`
// now, playing zeros included. A process that plays elsewhere does not count: the tap only hears
// the device it follows. False when the HAL cannot be asked. Non-real-time thread only (it
// allocates).
bool processesPlayOutput(pid_t except, AudioObjectID device) noexcept;

// The decision behind processesPlayOutput over `facts`, which answers runsOutput(process),
// pid(process, pid&) and playsOn(process, device), each false when it cannot be read. Idle
// processes cost one read: the pid and the devices are read only for those that run output.
template <typename Facts>
bool anyProcessPlays(const AudioObjectID* processes, size_t count, pid_t except,
                     AudioObjectID device, const Facts& facts) noexcept {
  for (size_t i = 0; i < count; ++i) {
    const AudioObjectID process = processes[i];
    if (!facts.runsOutput(process)) continue;
    pid_t pid = -1;
    if (except >= 0 && (!facts.pid(process, pid) || pid == except)) continue;
    if (facts.playsOn(process, device)) return true;
  }
  return false;
}

class SystemTap {
 public:
  explicit SystemTap(FrameRingView ring) noexcept : ring_(ring) {}
  ~SystemTap() { stop(); }
  SystemTap(const SystemTap&) = delete;
  SystemTap& operator=(const SystemTap&) = delete;

  // Creates the tap and the aggregate device and starts IO. Returns noErr, or the OSStatus of the
  // step named by failedStep(); on failure nothing is left behind.
  OSStatus start() noexcept;
  // Stops IO and destroys the aggregate device and the tap. Safe to call when stopped.
  void stop() noexcept;

  [[nodiscard]] bool isRunning() const noexcept { return proc_ != nullptr; }
  // While running: the tap, and the output device that clocks it (for change listeners).
  [[nodiscard]] AudioObjectID tapObject() const noexcept { return tap_; }
  [[nodiscard]] AudioObjectID outputDevice() const noexcept { return output_; }
  [[nodiscard]] TapFormat format() const noexcept { return format_; }
  // The Core Audio call that failed in the last start(), or "" after a successful start.
  [[nodiscard]] const char* failedStep() const noexcept { return failed_step_; }

  // Diagnostics; any thread.
  [[nodiscard]] uint64_t ioCycles() const noexcept {
    return io_cycles_.load(std::memory_order_relaxed);
  }
  [[nodiscard]] uint64_t framesCaptured() const noexcept {
    return frames_captured_.load(std::memory_order_relaxed);
  }
  // IO cycles whose buffer list did not have the tap's expected layout (skipped).
  [[nodiscard]] uint64_t skippedCycles() const noexcept {
    return skipped_cycles_.load(std::memory_order_relaxed);
  }

 private:
  static OSStatus ioProc(AudioObjectID device, const AudioTimeStamp* now,
                         const AudioBufferList* input, const AudioTimeStamp* input_time,
                         AudioBufferList* output, const AudioTimeStamp* output_time,
                         void* client) noexcept;
  void capture(const AudioBufferList* input) noexcept;
  OSStatus fail(const char* step, OSStatus status) noexcept;

  FrameRingView ring_;
  AudioObjectID tap_ = kAudioObjectUnknown;
  AudioObjectID aggregate_ = kAudioObjectUnknown;
  AudioObjectID output_ = kAudioObjectUnknown;
  AudioDeviceIOProcID proc_ = nullptr;
  TapFormat format_;
  // Layout of the tap's buffers at the end of the IO proc's input list. Written by start()
  // before AudioDeviceStart() and constant while IO runs.
  uint32_t tap_buffers_ = 0;
  uint32_t bytes_per_frame_ = 0;
  const char* failed_step_ = "";

  std::atomic<uint64_t> io_cycles_{0};
  std::atomic<uint64_t> frames_captured_{0};
  std::atomic<uint64_t> skipped_cycles_{0};
};

}  // namespace nmr
