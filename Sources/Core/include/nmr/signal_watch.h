// Whether the audio-capture permission looks denied (docs/PROMPT.md §6, first run). A denied
// grant hands the tap exact zeros, never an error, and no public call reports the grant. So the
// app watches what arrives: exact zeros for kSuspectS while another process plays output, with
// no sound ever seen, look like a denied grant. Anything but an exact zero means the grant works,
// and then nothing more needs watching (done()).
//
// An app that plays digital silence (a stopped DAW keeps its engine running) looks the same, so
// the app words this as a likely cause, never as a fact. Capture queue only; no allocation.
#pragma once

#include <nmr/frame_ring.h>

#include <cstddef>
#include <cstdint>

namespace nmr {

enum class Signal : uint8_t {
  kUnknown = 0,              // no sound yet, and no reason to suspect the grant
  kSound = 1,                // sound arrived: the grant works
  kSilenceWhilePlaying = 2,  // exact zeros while another process plays: likely denied
};

// What arrived since the last look.
enum class Samples : uint8_t {
  kNone = 0,   // no frames at all (a stalled or rebuilding tap): no evidence either way
  kZeros = 1,  // frames, every sample an exact zero
  kSound = 2,  // anything but an exact zero
};

class SignalWatch {
 public:
  static constexpr double kSuspectS = 4;  // another process plays this long, and only zeros come
  static constexpr double kCheckS = 0.5;  // how often the capture looks

  // `sound_seen_before`: an earlier run already got sound with this signature (the grant works).
  explicit SignalWatch(bool sound_seen_before = false) noexcept;

  // One check at `time` (seconds): what arrived since the last check, and whether another
  // process plays output now. Only zeros, without a break, while another process plays count
  // towards a suspicion; no frames is a break. A suspicion holds until sound arrives. A time that
  // is not a number changes nothing; one in the past counts at the last time.
  Signal check(double time, Samples samples, bool others_playing) noexcept;

  // A new tap: the zeros counted so far came from the old one, so counting starts again. A
  // suspicion or sound already reached stays.
  void restart() noexcept;

  [[nodiscard]] Signal signal() const noexcept { return signal_; }
  // Sound has arrived: the grant works and nothing more needs checking.
  [[nodiscard]] bool done() const noexcept { return signal_ == Signal::kSound; }

  // Whether any sample of `frames` interleaved stereo frames is anything but an exact zero
  // (a non-finite sample counts: a denied grant only ever delivers zeros).
  static bool hasNonZero(const float* interleaved, size_t frames) noexcept;

  // Looks at the frames of `ring` written since `checked` and moves `checked` to the newest
  // frame. After a long gap only the newest frames that can still be intact count (older ones
  // may have been overwritten). `scratch` holds kMaxWriteChunk interleaved stereo frames.
  // Reader side of the ring; no allocation.
  static Samples scan(const FrameRingView& ring, uint64_t& checked, float* scratch) noexcept;

 private:
  Signal signal_ = Signal::kUnknown;
  bool playing_ = false;  // another process has been playing since playing_since_
  double playing_since_ = 0;
  bool started_ = false;
  double last_time_ = 0;
};

}  // namespace nmr
