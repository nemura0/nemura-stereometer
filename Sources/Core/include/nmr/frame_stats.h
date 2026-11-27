// Frame pacing statistics (docs/PROMPT.md §7 budgets): how many frames reached the screen, how
// many did not, and how evenly the presented ones were spaced.
//
// Each frame reports when it was presented (the drawable's presentedTime) and the display
// period it was meant for. A frame never presented is dropped; so is every display period a gap
// between two presented frames skipped (an interval of n periods drops n − 1, rounded). The
// intervals between consecutive presented frames go into a fixed histogram of kBinMs bins, from
// which the percentiles come. A frame that was not presented, a new period or a gap longer than
// kMaxGapS (the view idled or was hidden) breaks the chain: the next interval is not measured
// and nothing is counted as dropped across it. Not thread-safe; no allocation.
#pragma once

#include <array>
#include <cstdint>

namespace nmr {

class FrameStats {
 public:
  static constexpr double kBinMs = 0.05;
  static constexpr int kBins = 2000;        // 0 … 100 ms; longer intervals land in the last bin
  static constexpr double kMaxGapS = 0.25;  // a longer gap is a pause, not dropped frames

  struct Summary {
    uint64_t frames = 0;     // reported
    uint64_t presented = 0;  // reached the screen
    uint64_t dropped = 0;    // never presented, plus display periods skipped between frames
    uint64_t intervals = 0;  // measured between consecutive presented frames
    double period_ms = 0;    // the latest frame's display period
    double p1_ms = 0;        // interval percentiles (bin centers); 0 with no intervals
    double p50_ms = 0;
    double p99_ms = 0;
    double max_ms = 0;       // the longest interval, exactly
    uint64_t worked = 0;     // frames whose work was reported (work())
    uint64_t over_period = 0;  // of those, CPU plus GPU time over their display period
    double cpu_p99_ms = 0;
    double cpu_max_ms = 0;
    double gpu_p99_ms = 0;
    double gpu_max_ms = 0;
  };

  void reset() noexcept;
  // A frame for a display period of `period_s`, presented at `time_s` (seconds, any monotonic
  // base), or not presented when `time_s` is 0. A time or period that is not a positive finite
  // number, or a time before the previous one, counts the frame as not presented.
  void frame(double time_s, double period_s) noexcept;
  // A frame's work: the render thread's time from the frame's start to its commit, and the
  // GPU's time on its commands (seconds). Times that are not finite or negative are ignored.
  void work(double cpu_s, double gpu_s, double period_s) noexcept;
  [[nodiscard]] Summary summary() const noexcept;

 private:
  using Histogram = std::array<uint32_t, kBins>;
  [[nodiscard]] static double percentile(const Histogram& bins, uint64_t count,
                                         double fraction) noexcept;
  static void add(Histogram& bins, double seconds) noexcept;

  Histogram cpu_bins_{};
  Histogram gpu_bins_{};
  uint64_t worked_ = 0;
  uint64_t over_period_ = 0;
  double cpu_max_s_ = 0;
  double gpu_max_s_ = 0;

  Histogram bins_{};
  uint64_t frames_ = 0;
  uint64_t presented_ = 0;
  uint64_t dropped_ = 0;
  uint64_t intervals_ = 0;
  double period_s_ = 0;
  double last_time_s_ = 0;  // the latest presented frame
  bool chained_ = false;     // and the next interval may be measured from it
  double max_s_ = 0;
};

}  // namespace nmr
