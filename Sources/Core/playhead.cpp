#include <nmr/playhead.h>

#include <algorithm>
#include <cmath>

namespace nmr {

void Playhead::prepare(double sample_rate, uint64_t readable) noexcept {
  sample_rate_ = std::isfinite(sample_rate) ? std::clamp(sample_rate, kMinRate, kMaxRate) : 48000;
  readable_ = readable;
  max_span_ = static_cast<uint64_t>(kMaxSpanS * sample_rate_);
  reset();
}

void Playhead::reset() noexcept {
  drawn_ = 0;
  startOver();
}

void Playhead::startOver() noexcept {
  timed_ = false;
  observed_ = false;
  seeded_ = false;
  last_time_ = 0;
  seen_ = 0;
  arrival_time_ = 0;
  largest_ = 0;
  anchor_ = 0;
  position_ = 0;
}

double Playhead::latencyFrames() const noexcept {
  return std::clamp(kLatencyBlocks * largest_, kMinLatencyS * sample_rate_,
                    kMaxLatencyS * sample_rate_);
}

double Playhead::latencySeconds() const noexcept { return latencyFrames() / sample_rate_; }

// The first block seen arriving: its frames went in just before this frame.
void Playhead::seed(double time, uint64_t written) noexcept {
  largest_ = static_cast<double>(written - seen_);
  anchor_ = static_cast<double>(written) - sample_rate_ * time;
  seen_ = written;
  arrival_time_ = time;
  seeded_ = true;
  position_ = std::max(0.0, static_cast<double>(written) - latencyFrames());
}

// A block arrived (written grew). A block can only be seen late, so its offset is a lower
// bound on the writer's: the estimate takes the highest. One far below means the source
// stopped and resumed. After a stalled frame, what it saw is no block size.
void Playhead::observe(double time, double dt, uint64_t written) noexcept {
  const double jump = static_cast<double>(written - seen_);
  const double offset = static_cast<double>(written) - sample_rate_ * time;
  if (dt <= kStallS) {
    const double memory = std::exp(-(time - arrival_time_) / kBlockMemoryS);
    largest_ = std::max(jump, largest_ * memory);
    if (offset < anchor_ - 2 * largest_) anchor_ = offset;
  }
  anchor_ = std::max(anchor_, offset);
  seen_ = written;
  arrival_time_ = time;
}

FrameSpan Playhead::advance(double time, uint64_t written) noexcept {
  if (!std::isfinite(time)) return {drawn_, drawn_};
  // A new source; checked before startOver(), which forgets the count but keeps drawn_.
  if (observed_ && written < seen_) reset();
  if (timed_ && std::abs(time - last_time_) > kMaxGapS) startOver();  // stopped, or a new clock
  if (timed_ && time <= last_time_) return {drawn_, drawn_};         // a frame out of order
  const double dt = timed_ ? time - last_time_ : 0.0;
  timed_ = true;
  last_time_ = time;
  const uint64_t oldest = written > readable_ ? written - readable_ : 0;
  drawn_ = std::max(drawn_, oldest);  // never begin where the ring may have overwritten

  if (!observed_) {
    // When this count arrived is unknown: draw only what comes after it.
    if (written > 0) {
      observed_ = true;
      seen_ = written;
      arrival_time_ = time;
      drawn_ = std::max(drawn_, written);
    }
    return {drawn_, drawn_};
  }
  if (!seeded_) {
    if (written > seen_) seed(time, written);
    return {drawn_, drawn_};
  }

  anchor_ -= kSettle * sample_rate_ * dt;
  if (written > seen_) observe(time, dt, written);

  const double latency = latencyFrames();
  const double writer = std::min(sample_rate_ * time + anchor_,
                                 static_cast<double>(seen_) + largest_);
  const double target = writer - latency;
  position_ += sample_rate_ * dt;
  position_ += (target - position_) * (1 - std::exp(-dt / kCorrectionS));
  position_ = std::clamp(position_, static_cast<double>(oldest), static_cast<double>(written));
  const uint64_t end = std::max(static_cast<uint64_t>(position_), drawn_);
  const uint64_t newest = end > max_span_ ? end - max_span_ : 0;
  const uint64_t begin = std::max(drawn_, newest);
  drawn_ = end;
  return {begin, end};
}

}  // namespace nmr
