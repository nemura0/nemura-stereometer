// A deterministic, music-like stereo signal that exercises a goniometer: drifting partials with
// slow panning, partly correlated noise, a centered kick every 0.5 s, and one second of
// antiphase every 8 s (from 7 s). Peaks near -2.5 dBFS; correlation about +0.8, -0.9 when
// inverted. Tests, baselines and snapshots play it (nmr_make_test_wav), and the app draws its
// mode thumbnails from it. Not for audio threads (it is cheap, but nothing needs it there).
#pragma once

#include <cstdint>

namespace nmr {

class TestMix {
 public:
  explicit TestMix(double sample_rate) noexcept;

  // The next `frames` stereo frames, interleaved: the same samples however the reads are split.
  void fill(float* interleaved, uint32_t frames) noexcept;
  // Moves on `frames` frames, as if they were read.
  void skip(uint64_t frames) noexcept;

 private:
  void next(float& left, float& right) noexcept;

  double rate_;
  double lowpass_;  // the noise's one-pole low-pass coefficient (2.5 kHz)
  double lp_left_ = 0;
  double lp_right_ = 0;
  uint64_t frame_ = 0;
};

}  // namespace nmr
