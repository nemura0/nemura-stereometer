#include <nmr/frame_stats.h>

#include <algorithm>
#include <cmath>

namespace nmr {

namespace {

bool positiveFinite(double value) noexcept { return std::isfinite(value) && value > 0; }

}  // namespace

void FrameStats::reset() noexcept { *this = FrameStats{}; }

void FrameStats::frame(double time_s, double period_s) noexcept {
  ++frames_;
  const bool presented =
      positiveFinite(time_s) && positiveFinite(period_s) && time_s >= last_time_s_;
  if (!presented) {
    ++dropped_;
    chained_ = false;  // the next interval spans this frame: not measured
    return;
  }
  ++presented_;
  if (period_s != period_s_) {
    period_s_ = period_s;
    chained_ = false;  // a new rate: no interval across the change
  }
  const double interval = time_s - last_time_s_;
  const bool measured = chained_ && interval > 0 && interval <= kMaxGapS;
  last_time_s_ = time_s;
  chained_ = true;
  if (!measured) return;  // the first of a chain, or after a pause
  ++intervals_;
  max_s_ = std::max(max_s_, interval);
  const double periods = std::round(interval / period_s);
  if (periods > 1) dropped_ += static_cast<uint64_t>(periods) - 1;
  add(bins_, interval);
}

void FrameStats::work(double cpu_s, double gpu_s, double period_s) noexcept {
  if (!std::isfinite(cpu_s) || !std::isfinite(gpu_s) || cpu_s < 0 || gpu_s < 0) return;
  ++worked_;
  if (positiveFinite(period_s) && cpu_s + gpu_s > period_s) ++over_period_;
  cpu_max_s_ = std::max(cpu_max_s_, cpu_s);
  gpu_max_s_ = std::max(gpu_max_s_, gpu_s);
  add(cpu_bins_, cpu_s);
  add(gpu_bins_, gpu_s);
}

void FrameStats::add(Histogram& bins, double seconds) noexcept {
  const double bin = std::floor(seconds * 1000 / kBinMs);
  ++bins[static_cast<size_t>(std::clamp(bin, 0.0, double{kBins - 1}))];
}

double FrameStats::percentile(const Histogram& bins, uint64_t count,
                              double fraction) noexcept {
  if (count == 0) return 0;
  const auto wanted = std::max<uint64_t>(
      static_cast<uint64_t>(std::ceil(fraction * static_cast<double>(count))), 1);
  uint64_t seen = 0;
  for (int i = 0; i < kBins; ++i) {
    seen += bins[static_cast<size_t>(i)];
    if (seen >= wanted) return (i + 0.5) * kBinMs;
  }
  return (kBins - 0.5) * kBinMs;
}

FrameStats::Summary FrameStats::summary() const noexcept {
  return {.frames = frames_,
          .presented = presented_,
          .dropped = dropped_,
          .intervals = intervals_,
          .period_ms = period_s_ * 1000,
          .p1_ms = percentile(bins_, intervals_, 0.01),
          .p50_ms = percentile(bins_, intervals_, 0.5),
          .p99_ms = percentile(bins_, intervals_, 0.99),
          .max_ms = max_s_ * 1000,
          .worked = worked_,
          .over_period = over_period_,
          .cpu_p99_ms = percentile(cpu_bins_, worked_, 0.99),
          .cpu_max_ms = cpu_max_s_ * 1000,
          .gpu_p99_ms = percentile(gpu_bins_, worked_, 0.99),
          .gpu_max_ms = gpu_max_s_ * 1000};
}

}  // namespace nmr
