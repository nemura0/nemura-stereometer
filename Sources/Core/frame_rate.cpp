#include <nmr/frame_rate.h>

#include <algorithm>
#include <cmath>

namespace nmr {

void FrameRateGovernor::configure(FrameRateChoice choice, double display_max_hz) noexcept {
  choice_ = choice;
  display_hz_ = std::isfinite(display_max_hz) && display_max_hz > 0
                    ? std::min(display_max_hz, kMaxDisplayHz)
                    : kDefaultDisplayHz;
  stepped_down_ = false;
  restart();
}

void FrameRateGovernor::restart() noexcept {
  started_ = false;
  start_time_ = 0;
  last_time_ = 0;
  buckets_.fill(Bucket{});  // the clock may start again lower: old buckets would look new
}

void FrameRateGovernor::count(double time, uint32_t frames, uint32_t late) noexcept {
  const auto index = static_cast<int64_t>(time / kBucketS);
  Bucket& bucket = buckets_[static_cast<size_t>(index % (kBuckets + 1))];
  if (bucket.index != index) bucket = Bucket{.index = index};
  bucket.frames += frames;
  bucket.late += late;
}

void FrameRateGovernor::frame(double time, bool late) noexcept {
  if (!(time >= 0 && time < kMaxTimeS)) return;  // also NaN
  if (started_ && time - last_time_ > kMaxGapS) restart();  // a pause: start over
  if (!started_) {
    started_ = true;
    start_time_ = time;
    last_time_ = time;
  }
  time = std::max(time, last_time_);  // a frame out of order counts at the last time
  // Periods with no frame are frames the link never delivered: late ones.
  const double periods = (time - last_time_) * rate();
  const auto missed = static_cast<uint32_t>(std::max(0.0, std::floor(periods - 0.5)));
  last_time_ = time;
  if (time - start_time_ < kWarmUpS) return;
  count(time, 1 + missed, (late ? 1 : 0) + missed);

  if (stepped_down_ || choice_ != FrameRateChoice::kAuto || display_hz_ <= kFallbackHz) return;
  if (time - start_time_ < kWarmUpS + kWindowS) return;  // not 2 s of frames yet
  const auto index = static_cast<int64_t>(time / kBucketS);
  uint64_t frames = 0;
  uint64_t lates = 0;
  for (const Bucket& b : buckets_) {
    if (b.index < index - kBuckets || b.index > index) continue;  // empty, too old, or not ours
    frames += b.frames;
    lates += b.late;
  }
  if (static_cast<double>(lates) > kMaxLateFraction * static_cast<double>(frames)) {
    stepped_down_ = true;
  }
}

double FrameRateGovernor::rate() const noexcept {
  switch (choice_) {
    case FrameRateChoice::k120: return std::min(120.0, display_hz_);
    case FrameRateChoice::k60: return std::min(60.0, display_hz_);
    case FrameRateChoice::k30: return std::min(30.0, display_hz_);
    case FrameRateChoice::kAuto: break;
  }
  return stepped_down_ ? std::min(kFallbackHz, display_hz_) : display_hz_;
}

}  // namespace nmr
