// `--feed <file.wav>` (docs/PROMPT.md §7, reproducible input): plays decoded audio into a ring of
// its own in real time, looping, from a thread of its own at user-interactive QoS (it feeds the
// display). It never runs ahead of real time: every kTickMs it writes the frames due since start,
// in blocks of kBlockFrames, as an audio device would.
#pragma once

#include <nmr/frame_ring.h>
#include <nmr/wav_file.h>

#include <atomic>
#include <cstdint>
#include <thread>

namespace nmr {

class FilePlayer {
 public:
  static constexpr uint32_t kBlockFrames = 256;
  static constexpr uint32_t kRingFrames = 1 << 17;  // 2.7 s at 48 kHz, like the capture's
  static constexpr int kTickMs = 5;

  // `audio` must hold at least one frame at a positive rate (wav::decode guarantees both).
  explicit FilePlayer(wav::Audio audio);
  ~FilePlayer();  // stops
  FilePlayer(const FilePlayer&) = delete;
  FilePlayer& operator=(const FilePlayer&) = delete;

  // Plays from where it stopped (the start the first time); false if its thread could not start.
  bool start() noexcept;
  void stop();   // returns once the thread has ended: nothing writes the ring after it

  // Where playing goes on after a tick that found `due` frames due and `played` played: past a
  // stall longer than half the ring (a debugger, App Nap), the missed audio is skipped rather
  // than written in one burst the reader would see lapped.
  static constexpr uint64_t catchUp(uint64_t played, uint64_t due) noexcept {
    if (due <= played || due - played <= kRingFrames / 2) return played;
    return due - due % kBlockFrames;
  }

  [[nodiscard]] FrameRingView view() const noexcept { return ring_.view(); }
  [[nodiscard]] double sampleRate() const noexcept { return audio_.sample_rate; }

 private:
  void run();

  const wav::Audio audio_;
  const LocalFrameRing ring_{kRingFrames};
  uint64_t position_ = 0;  // the next frame of the file to play; the thread's alone while it runs
  std::atomic<bool> running_{false};
  std::thread thread_;
};

}  // namespace nmr
