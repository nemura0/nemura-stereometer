#include <nmr/idle.h>

#include <algorithm>
#include <cfloat>
#include <cmath>

namespace nmr {

void IdleDetector::prepare(double trail_s) noexcept {
  setTrail(trail_s);
  idle_ = false;
  started_ = false;
  last_sound_ = 0;
  last_time_ = 0;
}

void IdleDetector::setTrail(double trail_s) noexcept {
  trail_s_ = std::isfinite(trail_s) && trail_s > 0 ? std::min(trail_s, kMaxTrailS) : 0;
}

bool IdleDetector::frame(double time, bool sound) noexcept {
  if (!std::isfinite(time)) return false;
  if (!started_) {
    started_ = true;
    last_sound_ = time;
    last_time_ = time;
  }
  time = std::max(time, last_time_);  // a frame out of order counts at the last time
  last_time_ = time;
  if (idle_) return false;
  if (sound) last_sound_ = time;
  if (time - last_sound_ <= trail_s_ + kHoldS) return false;
  idle_ = true;
  return true;
}

void IdleDetector::wake(double time) noexcept {
  if (!std::isfinite(time)) return;
  idle_ = false;
  started_ = true;
  last_time_ = std::max(time, last_time_);
  last_sound_ = last_time_;
}

bool IdleDetector::hasSound(const float* interleaved, size_t frames) noexcept {
  if (interleaved == nullptr) return false;
  for (size_t i = 0; i < 2 * frames; ++i) {
    const float level = std::fabs(interleaved[i]);
    if (level > kSilence && level <= FLT_MAX) return true;  // NaN and ±inf are not sound
  }
  return false;
}

}  // namespace nmr
