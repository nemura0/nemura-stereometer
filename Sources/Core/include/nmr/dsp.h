// Stereo analysis for the meter: point mapping, color coordinates, correlation and balance, and
// auto-gain. It runs on the render thread at the paced playhead, never on an audio thread. Each
// meter view owns one Analyzer; nothing allocates after construction.
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace nmr::dsp {

inline constexpr float kMinLogRangeDb = 24;
inline constexpr float kMaxLogRangeDb = 72;
inline constexpr float kDefaultLogRangeDb = 48;
inline constexpr float kMinGainDb = -24;
inline constexpr float kMaxGainDb = 36;
inline constexpr double kMinIntegrationS = 0.05;
inline constexpr double kMaxIntegrationS = 3.0;
inline constexpr double kDefaultIntegrationS = 0.3;
// Sample rates outside this range are clamped; NaN counts as the default.
inline constexpr double kMinSampleRate = 8000;
inline constexpr double kMaxSampleRate = 768000;
inline constexpr double kDefaultSampleRate = 48000;

enum class Scale : uint8_t { kLinear, kLog };
enum class Orientation : uint8_t { kMidSide, kLeftRight };
enum class ColorMode : uint8_t { kFrequency, kSolid, kAmplitude, kMidSide };
enum class AutoGainMode : uint8_t { kOff, kSlow, kFast };

struct MapParams {
  float gain = 1;  // linear, applied first
  Scale scale = Scale::kLinear;
  float log_range_db = kDefaultLogRangeDb;          // kMinLogRangeDb ... kMaxLogRangeDb
  bool half = false;                                // folded to the upper half, 2:1 viewport
  Orientation orientation = Orientation::kMidSide;  // half views are always M/S
};

struct Point {
  float x = 0;
  float y = 0;
};

// `value` within lo ... hi; NaN becomes `fallback`.
template <typename T>
[[nodiscard]] constexpr T clampOr(T value, T lo, T hi, T fallback) noexcept {
  return value != value ? fallback : std::clamp(value, lo, hi);
}

// The distance from the center on the log scale: 1 at full scale and above, 0 at -range_db and
// below, and 0 for 0 or NaN.
[[nodiscard]] inline float logRadius(float radius, float range_db) noexcept {
  if (!(radius > 0)) return 0;
  return std::clamp(1 + 20 * std::log10(radius) / range_db, 0.0f, 1.0f);
}

// One stereo sample (finite) to a point in the view, X and Y within -1 ... 1 at full scale.
// M/S: X = side (right is positive), Y = mid, and full scale is the unit diamond. L/R: X = left,
// Y = right. Log: the distance from the center becomes logRadius() and the direction is kept.
// Half: points below the X axis are mirrored through the center onto the upper half (which keeps
// their stereo side), then Y is stretched from 0 ... 1 to -1 ... 1 for a 2:1 view.
[[nodiscard]] inline Point mapPoint(float left, float right, const MapParams& params) noexcept {
  const float l = left * params.gain;
  const float r = right * params.gain;
  float x = (r - l) / 2;
  float y = (l + r) / 2;
  if (params.scale == Scale::kLog) {
    const float radius = std::sqrt(x * x + y * y);
    const float scale = radius > 0 ? logRadius(radius, params.log_range_db) / radius : 0.0f;
    x *= scale;
    y *= scale;
  }
  if (params.half) {
    if (y < 0) {
      x = -x;
      y = -y;
    }
    return {x, 2 * y - 1};
  }
  if (params.orientation == Orientation::kLeftRight) return {y - x, y + x};
  return {x, y};
}

// Amplitude color: the sample's distance from the center (the M/S radius) on the log scale.
[[nodiscard]] inline float amplitudeT(float left, float right, float range_db) noexcept {
  return logRadius(std::sqrt((left * left + right * right) / 2), range_db);
}

// Mid-side color: the side share of the sample, 0 for mono, 0.5 for one channel, 1 for
// anti-phase (and 0 for silence).
[[nodiscard]] inline float midSideT(float left, float right) noexcept {
  const float mid = std::abs(left + right);
  const float side = std::abs(right - left);
  const float sum = mid + side;
  return sum > 0 ? side / sum : 0.0f;
}

// Frequency color: where the sound's energy sits between the bass (0) and the treble (1). Each
// channel is split at 250 Hz and 3 kHz; the band levels of both channels, smoothed over 15 ms and
// weighted for music's falling spectrum, give t = (half the mids + the highs) / all, so side-only
// content has a color too. In silence (all bands under -140 dB) the last color is held.
class BandColor {
 public:
  BandColor() noexcept { prepare(kDefaultSampleRate); }
  void prepare(double sample_rate) noexcept;  // also resets
  void reset() noexcept;
  float process(float left, float right) noexcept;

 private:
  struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;
    double process(double x) noexcept {
      const double y = b0 * x + z1;
      z1 = b1 * x - a1 * y + z2;
      z2 = b2 * x - a2 * y;
      return y;
    }
  };
  struct Bands {
    Biquad low;             // low-pass at 250 Hz
    Biquad mid_high_pass;   // 250 Hz, then
    Biquad mid_low_pass;    // 3 kHz
    Biquad high;            // high-pass at 3 kHz
  };

  std::array<Bands, 2> channels_{};
  double smoothing_ = 0;  // one-pole coefficient
  std::array<double, 3> levels_{};
  float t_ = 0.5f;
};

// Correlation and balance, averaged over an exponential window of the integration time.
class StereoMeter {
 public:
  StereoMeter() noexcept { prepare(kDefaultSampleRate, kDefaultIntegrationS); }
  void prepare(double sample_rate, double integration_s) noexcept;  // also resets
  void setIntegration(double integration_s) noexcept;               // keeps the averages
  void reset() noexcept;
  void process(float left, float right) noexcept;
  // -1 (anti-phase) ... +1 (mono); 0 while either channel is silent (under -120 dBFS).
  [[nodiscard]] float correlation() const noexcept;
  // (R - L) / (R + L) of the channel powers: -1 left only ... +1 right only.
  [[nodiscard]] float balance() const noexcept;
  // R over L power in dB, within -60 ... +60.
  [[nodiscard]] float balanceDb() const noexcept;

 private:
  double sample_rate_ = kDefaultSampleRate;
  double coefficient_ = 0;
  double left_ = 0;   // mean L^2
  double right_ = 0;  // mean R^2
  double cross_ = 0;  // mean L * R
};

// Auto-gain: brings the loudest recent samples to -3 dB of full scale on the display. The held
// peak rises at once and falls at the mode's pace, and the gain follows it smoothly. Samples
// under -72 dBFS are skipped, so silence and noise floors hold the gain where it was.
class AutoGain {
 public:
  AutoGain() noexcept { prepare(kDefaultSampleRate); }
  void prepare(double sample_rate) noexcept;  // keeps the mode and the gain, forgets the peak
  void setMode(AutoGainMode mode) noexcept;
  void reset(float gain_db) noexcept;  // starts again from gain_db (clamped to the gain range)
  void feed(float left, float right) noexcept;
  // After feeding `frames` samples: updates and returns the gain (dB). Off: the gain is kept.
  float update(uint32_t frames) noexcept;
  [[nodiscard]] float gainDb() const noexcept { return static_cast<float>(gain_db_); }

 private:
  double sample_rate_ = kDefaultSampleRate;
  AutoGainMode mode_ = AutoGainMode::kOff;
  double gain_db_ = 0;
  double peak_ = 0;        // held peak of the squared M/S radius
  double block_peak_ = 0;  // since the last update
  bool active_ = false;    // a sample since the last update was loud enough to count
};

struct AnalyzerConfig {
  MapParams map;  // map.gain is the manual gain; auto-gain replaces it
  ColorMode color = ColorMode::kFrequency;
  AutoGainMode auto_gain = AutoGainMode::kOff;
  double integration_s = kDefaultIntegrationS;
};

// Everything one meter view needs from a block of interleaved stereo frames: one point and one
// color coordinate (0 ... 1; 0 for solid color) per frame, the meters and the gain. Non-finite
// samples count as silence; values beyond +60 dBFS are clamped. Settings and sample rates out of
// range are clamped.
class Analyzer {
 public:
  void prepare(double sample_rate) noexcept;  // also resets
  void configure(const AnalyzerConfig& config) noexcept;
  void reset() noexcept;
  void process(const float* interleaved, uint32_t frames, Point* points, float* color) noexcept;
  [[nodiscard]] float correlation() const noexcept { return meter_.correlation(); }
  [[nodiscard]] float balance() const noexcept { return meter_.balance(); }
  [[nodiscard]] float balanceDb() const noexcept { return meter_.balanceDb(); }
  [[nodiscard]] float gainDb() const noexcept;

 private:
  [[nodiscard]] bool autoGainOn() const noexcept {
    return config_.auto_gain != AutoGainMode::kOff;
  }
  float colorOf(float left, float right, float gain) noexcept;

  AnalyzerConfig config_;
  float manual_gain_db_ = 0;
  BandColor band_color_;
  StereoMeter meter_;
  AutoGain auto_gain_;
};

}  // namespace nmr::dsp
