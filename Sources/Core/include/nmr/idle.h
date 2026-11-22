// When the meter stops drawing (docs/PROMPT.md §7): after silence longer than the trail time
// + 250 ms it draws one clear frame and the link stops (0 fps); a cheap low-rate check of the
// newest samples wakes it on the first sound. Frames that drew no new samples count as silent.
// Render thread only; no allocation.
#pragma once

#include <cstddef>

namespace nmr {

class IdleDetector {
 public:
  static constexpr double kHoldS = 0.25;       // beyond the trail time
  static constexpr float kSilence = 1e-5f;     // −100 dBFS: anything quieter is silence
  static constexpr double kWakeCheckS = 0.1;   // how often a stopped meter looks for sound
  static constexpr double kMaxTrailS = 10;     // longer trails count as this

  // Starts awake, counting silence from the first frame. Negative or non-finite trails are 0.
  void prepare(double trail_s) noexcept;
  void setTrail(double trail_s) noexcept;

  // A frame drawn at `time` (seconds; one out of order counts at the last time, a non-finite
  // one not at all). True when the meter goes idle: draw this frame clear and stop the link.
  bool frame(double time, bool sound) noexcept;
  // Sound arrived while idle (from the low-rate check): start drawing again. A time that is not
  // a number changes nothing; one in the past counts at the last time.
  void wake(double time) noexcept;
  [[nodiscard]] bool idle() const noexcept { return idle_; }

  // Whether any sample of `frames` interleaved stereo frames is louder than kSilence
  // (non-finite samples are not sound).
  static bool hasSound(const float* interleaved, size_t frames) noexcept;

 private:
  double trail_s_ = 0;
  bool idle_ = false;
  bool started_ = false;
  double last_sound_ = 0;
  double last_time_ = 0;
};

}  // namespace nmr
