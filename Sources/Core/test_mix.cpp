#include "nmr/test_mix.h"

#include <cmath>

namespace nmr {

namespace {

constexpr double kPi = 3.14159265358979323846;

struct Partial {
  double freq, amp, pan_rate, pan_phase;
};

constexpr Partial kPartials[] = {
    {110.0, 0.20, 0.07, 0.0}, {220.5, 0.14, 0.11, 1.3}, {330.7, 0.10, 0.05, 2.1},
    {659.3, 0.07, 0.17, 0.4}, {1318.5, 0.04, 0.23, 3.0},
};

// Deterministic white noise in [-1, 1).
double noise(uint64_t n) noexcept {
  uint64_t x = (n + 1) * 0x9E3779B97F4A7C15ull;
  x ^= x >> 31;
  x *= 0xBF58476D1CE4E5B9ull;
  x ^= x >> 27;
  return static_cast<float>(static_cast<double>(x >> 40) / static_cast<double>(1ull << 23) - 1.0);
}

}  // namespace

TestMix::TestMix(double sample_rate) noexcept
    : rate_(sample_rate), lowpass_(1.0 - std::exp(-2 * kPi * 2500.0 / sample_rate)) {}

void TestMix::fill(float* interleaved, uint32_t frames) noexcept {
  for (uint32_t i = 0; i < frames; ++i) next(interleaved[2 * i], interleaved[2 * i + 1]);
}

void TestMix::skip(uint64_t frames) noexcept {
  float left = 0;
  float right = 0;
  for (uint64_t i = 0; i < frames; ++i) next(left, right);  // the noise filter needs every one
}

void TestMix::next(float& out_left, float& out_right) noexcept {
  const uint64_t i = frame_++;
  const double t = static_cast<double>(i) / rate_;
  double left = 0;
  double right = 0;
  for (const Partial& p : kPartials) {
    const double s = p.amp * std::sin(2 * kPi * p.freq * t);
    const double pan = 0.5 + 0.45 * std::sin(2 * kPi * p.pan_rate * t + p.pan_phase);
    left += s * std::sqrt(1.0 - pan);
    right += s * std::sqrt(pan);
  }
  // Noise with correlation about 0.6 between channels.
  const double shared = noise(i * 2);
  lp_left_ += lowpass_ * ((0.8 * shared + 0.6 * noise(i * 2 + 1)) - lp_left_);
  lp_right_ += lowpass_ * ((0.8 * shared + 0.6 * noise(i * 2 + 7919)) - lp_right_);
  left += 0.12 * lp_left_;
  right += 0.12 * lp_right_;
  // Kick: 55 Hz sine with a fast decay, every 0.5 s, centered.
  const double beat = std::fmod(t, 0.5);
  const double kick = 0.45 * std::exp(-beat * 18.0) * std::sin(2 * kPi * 55.0 * beat);
  left += kick;
  right += kick;
  // One second of antiphase every 8 s (correlation goes negative).
  if (std::fmod(t, 8.0) >= 7.0) right = -right;
  out_left = static_cast<float>(left);
  out_right = static_cast<float>(right);
}

}  // namespace nmr
