#include <nmr/signal_watch.h>

#include <algorithm>
#include <cmath>

namespace nmr {

SignalWatch::SignalWatch(bool sound_seen_before) noexcept
    : signal_(sound_seen_before ? Signal::kSound : Signal::kUnknown) {}

Signal SignalWatch::check(double time, Samples samples, bool others_playing) noexcept {
  if (done()) return signal_;
  if (samples == Samples::kSound) {
    signal_ = Signal::kSound;
    return signal_;
  }
  if (!std::isfinite(time)) return signal_;
  if (started_ && time < last_time_) time = last_time_;
  started_ = true;
  last_time_ = time;
  if (samples == Samples::kNone || !others_playing) {
    playing_ = false;
    return signal_;
  }
  if (!playing_) {
    playing_ = true;
    playing_since_ = time;
  }
  if (time - playing_since_ >= kSuspectS) signal_ = Signal::kSilenceWhilePlaying;
  return signal_;
}

void SignalWatch::restart() noexcept { playing_ = false; }

Samples SignalWatch::scan(const FrameRingView& ring, uint64_t& checked, float* scratch) noexcept {
  const uint64_t written = ring.framesWritten();
  // A new ring counts from 0; a count that went back means one we have not seen: start over.
  if (written < checked) checked = 0;
  const uint64_t window = ring.capacity() - kMaxWriteChunk;
  uint64_t first = written - checked > window ? written - window : checked;
  checked = written;
  Samples found = Samples::kNone;
  while (first < written) {
    const auto count = static_cast<uint32_t>(std::min<uint64_t>(written - first, kMaxWriteChunk));
    const uint64_t intact = ring.read(first, count, scratch);
    const auto skip = static_cast<uint32_t>(std::min<uint64_t>(intact - first, count));
    if (skip < count) {
      if (hasNonZero(scratch + size_t{skip} * 2, count - skip)) return Samples::kSound;
      found = Samples::kZeros;
    }
    first += count;
  }
  return found;
}

bool SignalWatch::hasNonZero(const float* interleaved, size_t frames) noexcept {
  if (interleaved == nullptr) return false;
  const size_t samples = frames * 2;
  for (size_t i = 0; i < samples; ++i) {
    // A NaN compares unequal to zero too: it counts.
    if (interleaved[i] != 0.0f) return true;
  }
  return false;
}

}  // namespace nmr
