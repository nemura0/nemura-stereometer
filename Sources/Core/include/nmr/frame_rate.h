// The display link's frame rate (docs/PROMPT.md §7): always a fixed rate (min = max).
//
// Auto runs at the display's maximum. If more than 1 % of the frames over the last 2 s were
// late, Auto steps down to a fixed 60 Hz and stays there until it is configured again (the
// Settings window says so). Frames the link never delivered (from a gap of 1.5 periods) count
// as late; a pause of more than 250 ms starts the count over, as does restart(). The
// first 250 ms after a start do not count (shaders compiling, the first drawables), and nothing
// is decided before 2 s of frames after that. The window is the last 2.0–2.1 s (20 buckets of
// 100 ms and the current one). A forced rate (120, 60 or 30) never steps down; none
// goes above the display's maximum. Render thread only; no allocation.
#pragma once

#include <array>
#include <cstdint>

namespace nmr {

// The frame_rate setting's choices, in its order.
enum class FrameRateChoice : uint8_t { kAuto, k120, k60, k30 };

class FrameRateGovernor {
 public:
  static constexpr double kWindowS = 2.0;
  static constexpr double kMaxLateFraction = 0.01;
  static constexpr double kFallbackHz = 60;
  static constexpr double kDefaultDisplayHz = 60;  // for a display that reports no rate
  static constexpr double kMaxDisplayHz = 1000;   // display rates are held to this
  static constexpr double kMaxTimeS = 1e15;        // later times are ignored
  static constexpr double kMaxGapS = 0.25;         // a longer pause starts the count over
  static constexpr double kWarmUpS = 0.25;         // not counted after a start

  FrameRateGovernor() noexcept { configure(FrameRateChoice::kAuto, kDefaultDisplayHz); }

  // Clears the step-down and the window.
  void configure(FrameRateChoice choice, double display_max_hz) noexcept;
  // The link starts again (after idle or occlusion): forget the old window.
  void restart() noexcept;
  // One frame at `time` (seconds; one out of order counts at the last time, one that is
  // negative, not a number or beyond kMaxTimeS not at all); `late`: presented after its target, or skipped.
  void frame(double time, bool late) noexcept;

  [[nodiscard]] double rate() const noexcept;
  [[nodiscard]] bool steppedDown() const noexcept { return stepped_down_; }

 private:
  static constexpr int kBuckets = 20;  // full ones in the window, plus the current one
  static constexpr double kBucketS = kWindowS / kBuckets;
  void count(double time, uint32_t frames, uint32_t late) noexcept;
  struct Bucket {
    int64_t index = -1;  // floor(time / kBucketS), or -1 when empty
    uint32_t frames = 0;
    uint32_t late = 0;
  };

  FrameRateChoice choice_ = FrameRateChoice::kAuto;
  double display_hz_ = kDefaultDisplayHz;
  bool stepped_down_ = false;
  bool started_ = false;
  double start_time_ = 0;
  double last_time_ = 0;
  std::array<Bucket, kBuckets + 1> buckets_{};
};

}  // namespace nmr
