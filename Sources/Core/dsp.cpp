#include <nmr/dsp.h>

#include <numbers>

namespace nmr::dsp {

namespace {

double usableRate(double sample_rate) {
  return clampOr(sample_rate, kMinSampleRate, kMaxSampleRate, kDefaultSampleRate);
}

float dbToGain(float db) { return std::pow(10.0f, db / 20); }

// ---- Band color ----

constexpr double kLowCrossoverHz = 250;
constexpr double kHighCrossoverHz = 3000;
constexpr double kQ = std::numbers::sqrt2 / 2;  // Butterworth
constexpr double kSmoothingS = 0.015;
// Music's spectrum falls with frequency; these weights put typical mixes mid-colormap.
constexpr double kLowWeight = 1.0;
constexpr double kMidWeight = 1.6;
constexpr double kHighWeight = 2.5;
constexpr double kHoldBelow = 1e-7;  // -140 dB

enum class Pass : uint8_t { kLow, kHigh };

// RBJ cookbook second-order low- or high-pass, normalized.
template <typename Biquad>
void design(Biquad& filter, Pass pass, double frequency, double sample_rate) {
  const double w0 = 2 * std::numbers::pi * frequency / sample_rate;
  const double cos_w0 = std::cos(w0);
  const double alpha = std::sin(w0) / (2 * kQ);
  const double a0 = 1 + alpha;
  const double edge = pass == Pass::kLow ? 1 - cos_w0 : 1 + cos_w0;
  filter.b0 = edge / 2 / a0;
  filter.b1 = (pass == Pass::kLow ? edge : -edge) / a0;
  filter.b2 = filter.b0;
  filter.a1 = -2 * cos_w0 / a0;
  filter.a2 = (1 - alpha) / a0;
}

// ---- Meters ----

constexpr double kSilentPower = 1e-12;  // -120 dBFS
constexpr double kMaxBalanceDb = 60;

// ---- Auto-gain ----

constexpr double kTargetDb = -3;
constexpr double kQuietPower = 6.309573444801933e-8;  // -72 dBFS, squared

struct Pace {
  double release_db_per_s;  // how fast the held peak falls
  double time_constant_s;   // how fast the gain follows it
};
constexpr Pace kSlowPace{2, 1.5};
constexpr Pace kFastPace{6, 0.2};

// ---- Analyzer ----

constexpr float kMaxSample = 1000;  // +60 dBFS

float sanitize(float sample) {
  return std::isfinite(sample) ? std::clamp(sample, -kMaxSample, kMaxSample) : 0.0f;
}

}  // namespace

// ---- BandColor ----

void BandColor::prepare(double sample_rate) noexcept {
  const double rate = usableRate(sample_rate);
  for (Bands& bands : channels_) {
    design(bands.low, Pass::kLow, kLowCrossoverHz, rate);
    design(bands.mid_high_pass, Pass::kHigh, kLowCrossoverHz, rate);
    design(bands.mid_low_pass, Pass::kLow, kHighCrossoverHz, rate);
    design(bands.high, Pass::kHigh, kHighCrossoverHz, rate);
  }
  smoothing_ = 1 - std::exp(-1 / (kSmoothingS * rate));
  reset();
}

void BandColor::reset() noexcept {
  for (Bands& bands : channels_) {
    for (Biquad* filter : {&bands.low, &bands.mid_high_pass, &bands.mid_low_pass, &bands.high}) {
      filter->z1 = 0;
      filter->z2 = 0;
    }
  }
  levels_ = {};
  t_ = 0.5f;
}

float BandColor::process(float left, float right) noexcept {
  std::array<double, 3> level{};
  for (size_t channel = 0; channel < channels_.size(); ++channel) {
    const double x = channel == 0 ? left : right;
    Bands& bands = channels_[channel];
    level[0] += std::abs(bands.low.process(x));
    level[1] += std::abs(bands.mid_low_pass.process(bands.mid_high_pass.process(x)));
    level[2] += std::abs(bands.high.process(x));
  }
  for (size_t band = 0; band < levels_.size(); ++band) {
    levels_[band] += smoothing_ * (level[band] - levels_[band]);
  }
  const double low = kLowWeight * levels_[0];
  const double mid = kMidWeight * levels_[1];
  const double high = kHighWeight * levels_[2];
  const double total = low + mid + high;
  if (total > kHoldBelow) t_ = static_cast<float>((mid / 2 + high) / total);
  return t_;
}

// ---- StereoMeter ----

void StereoMeter::prepare(double sample_rate, double integration_s) noexcept {
  sample_rate_ = usableRate(sample_rate);
  setIntegration(integration_s);
  reset();
}

void StereoMeter::setIntegration(double integration_s) noexcept {
  const double seconds =
      clampOr(integration_s, kMinIntegrationS, kMaxIntegrationS, kDefaultIntegrationS);
  coefficient_ = 1 - std::exp(-1 / (seconds * sample_rate_));
}

void StereoMeter::reset() noexcept {
  left_ = 0;
  right_ = 0;
  cross_ = 0;
}

void StereoMeter::process(float left, float right) noexcept {
  const double l = left;
  const double r = right;
  left_ += coefficient_ * (l * l - left_);
  right_ += coefficient_ * (r * r - right_);
  cross_ += coefficient_ * (l * r - cross_);
}

float StereoMeter::correlation() const noexcept {
  if (left_ <= kSilentPower || right_ <= kSilentPower) return 0;
  return static_cast<float>(std::clamp(cross_ / std::sqrt(left_ * right_), -1.0, 1.0));
}

float StereoMeter::balance() const noexcept {
  if (left_ <= kSilentPower && right_ <= kSilentPower) return 0;
  return static_cast<float>((right_ - left_) / (right_ + left_));
}

float StereoMeter::balanceDb() const noexcept {
  const bool left_silent = left_ <= kSilentPower;
  const bool right_silent = right_ <= kSilentPower;
  if (left_silent && right_silent) return 0;
  if (left_silent) return static_cast<float>(kMaxBalanceDb);
  if (right_silent) return static_cast<float>(-kMaxBalanceDb);
  return static_cast<float>(
      std::clamp(10 * std::log10(right_ / left_), -kMaxBalanceDb, kMaxBalanceDb));
}

// ---- AutoGain ----

void AutoGain::prepare(double sample_rate) noexcept {
  sample_rate_ = usableRate(sample_rate);
  peak_ = 0;
  block_peak_ = 0;
  active_ = false;
}

void AutoGain::setMode(AutoGainMode mode) noexcept { mode_ = mode; }

void AutoGain::reset(float gain_db) noexcept {
  gain_db_ = clampOr(gain_db, kMinGainDb, kMaxGainDb, 0.0f);
  peak_ = 0;
  block_peak_ = 0;
  active_ = false;
}

void AutoGain::feed(float left, float right) noexcept {
  const double l = left;
  const double r = right;
  const double power = (l * l + r * r) / 2;  // the squared M/S radius
  if (!(power >= kQuietPower)) return;
  block_peak_ = std::max(block_peak_, power);
  active_ = true;
}

float AutoGain::update(uint32_t frames) noexcept {
  if (mode_ != AutoGainMode::kOff && active_) {
    const Pace& pace = mode_ == AutoGainMode::kFast ? kFastPace : kSlowPace;
    const double elapsed_s = frames / sample_rate_;
    const double release = std::pow(10.0, -pace.release_db_per_s * elapsed_s / 10);
    peak_ = std::max(block_peak_, peak_ * release);
    const double target = std::clamp(kTargetDb - 10 * std::log10(peak_), double{kMinGainDb},
                                     double{kMaxGainDb});
    gain_db_ += (target - gain_db_) * (1 - std::exp(-elapsed_s / pace.time_constant_s));
  }
  block_peak_ = 0;
  active_ = false;
  return gainDb();
}

// ---- Analyzer ----

void Analyzer::prepare(double sample_rate) noexcept {
  band_color_.prepare(sample_rate);
  meter_.prepare(sample_rate, config_.integration_s);
  auto_gain_.prepare(sample_rate);
  reset();
}

void Analyzer::configure(const AnalyzerConfig& config) noexcept {
  const bool was_automatic = autoGainOn();
  config_ = config;
  MapParams& map = config_.map;
  map.gain = clampOr(map.gain, dbToGain(kMinGainDb), dbToGain(kMaxGainDb), 1.0f);
  map.log_range_db =
      clampOr(map.log_range_db, kMinLogRangeDb, kMaxLogRangeDb, kDefaultLogRangeDb);
  manual_gain_db_ = 20 * std::log10(map.gain);
  meter_.setIntegration(config_.integration_s);
  auto_gain_.setMode(config_.auto_gain);
  if (autoGainOn() && !was_automatic) auto_gain_.reset(manual_gain_db_);
}

void Analyzer::reset() noexcept {
  band_color_.reset();
  meter_.reset();
  auto_gain_.reset(manual_gain_db_);
}

float Analyzer::gainDb() const noexcept {
  return autoGainOn() ? auto_gain_.gainDb() : manual_gain_db_;
}

void Analyzer::process(const float* interleaved, uint32_t frames, Point* points,
                       float* color) noexcept {
  const bool automatic = autoGainOn();
  MapParams map = config_.map;
  if (automatic) map.gain = dbToGain(auto_gain_.gainDb());
  for (uint32_t i = 0; i < frames; ++i) {
    const float left = sanitize(interleaved[2 * size_t{i}]);
    const float right = sanitize(interleaved[2 * size_t{i} + 1]);
    meter_.process(left, right);
    if (automatic) auto_gain_.feed(left, right);
    points[i] = mapPoint(left, right, map);
    color[i] = colorOf(left, right, map.gain);
  }
  if (automatic && frames > 0) auto_gain_.update(frames);
}

float Analyzer::colorOf(float left, float right, float gain) noexcept {
  switch (config_.color) {
    case ColorMode::kFrequency:
      return band_color_.process(left, right);
    case ColorMode::kAmplitude:
      return amplitudeT(left * gain, right * gain, config_.map.log_range_db);
    case ColorMode::kMidSide:
      return midSideT(left, right);
    case ColorMode::kSolid:
      break;
  }
  return 0;
}

}  // namespace nmr::dsp
