// Stereo analysis: point mapping, color coordinates, band color, correlation, balance and
// auto-gain (Sources/Core/include/nmr/dsp.h).
#include <doctest/doctest.h>
#include <nmr/dsp.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <numbers>
#include <utility>
#include <vector>

namespace dsp = nmr::dsp;
using doctest::Approx;

namespace {

constexpr double kRate = 48000;
constexpr uint32_t kBlock = 512;

float dbAmplitude(double db) { return static_cast<float>(std::pow(10.0, db / 20.0)); }

uint64_t count(double seconds, double rate) {
  return static_cast<uint64_t>(std::llround(seconds * rate));
}

float sineAt(double frequency, double rate, uint64_t n, double phase = 0) {
  return static_cast<float>(
      std::sin(2 * std::numbers::pi * frequency * static_cast<double>(n) / rate + phase));
}

// Deterministic white noise in [-1, 1).
class Noise {
 public:
  explicit Noise(uint32_t seed) : state_(seed) {}
  float next() {
    state_ = state_ * 1664525u + 1013904223u;
    return static_cast<float>(state_ >> 8) / 8388608.0f - 1.0f;
  }

 private:
  uint32_t state_;
};

#define CHECK_POINT(point, expected_x, expected_y)               \
  do {                                                           \
    const dsp::Point p_ = (point);                               \
    CHECK(p_.x == Approx(expected_x).epsilon(1e-5));             \
    CHECK(p_.y == Approx(expected_y).epsilon(1e-5));             \
  } while (false)

// The frequency color of a steady tone: the mean over 100 ms, after 400 ms to settle.
float toneColor(double frequency, double rate, bool anti_phase) {
  dsp::BandColor color;
  color.prepare(rate);
  const uint64_t settle = count(0.4, rate);
  const uint64_t measure = count(0.1, rate);
  double sum = 0;
  for (uint64_t n = 0; n < settle + measure; ++n) {
    const float s = 0.5f * sineAt(frequency, rate, n);
    const float t = color.process(s, anti_phase ? -s : s);
    if (n >= settle) sum += t;
  }
  return static_cast<float>(sum / static_cast<double>(measure));
}

// Feeds `seconds` of stereo frames made by `make(n)` to a meter.
template <typename Make>
void feed(dsp::StereoMeter& meter, double seconds, Make make) {
  const uint64_t frames = count(seconds, kRate);
  for (uint64_t n = 0; n < frames; ++n) {
    const auto [left, right] = make(n);
    meter.process(left, right);
  }
}

// A mono tone through auto-gain in blocks, as the render thread feeds it. Returns the gain (dB).
float autoGainOnTone(dsp::AutoGain& gain, float amplitude, double seconds) {
  const uint64_t blocks = count(seconds, kRate / kBlock);
  float db = gain.gainDb();
  uint64_t n = 0;
  for (uint64_t block = 0; block < blocks; ++block) {
    for (uint32_t k = 0; k < kBlock; ++k, ++n) {
      const float s = amplitude * sineAt(440, kRate, n);
      gain.feed(s, s);
    }
    db = gain.update(kBlock);
  }
  return db;
}

// Interleaved frames through an analyzer in blocks; keeps the last block's output.
struct AnalyzerRun {
  std::vector<dsp::Point> points = std::vector<dsp::Point>(kBlock);
  std::vector<float> color = std::vector<float>(kBlock);
};

template <typename Make>
AnalyzerRun runAnalyzer(dsp::Analyzer& analyzer, double seconds, Make make) {
  AnalyzerRun run;
  std::vector<float> frames(size_t{kBlock} * 2);
  const uint64_t blocks = count(seconds, kRate / kBlock);
  uint64_t n = 0;
  for (uint64_t block = 0; block < blocks; ++block) {
    for (uint32_t k = 0; k < kBlock; ++k, ++n) {
      const auto [left, right] = make(n);
      frames[2 * k] = left;
      frames[2 * k + 1] = right;
    }
    analyzer.process(frames.data(), kBlock, run.points.data(), run.color.data());
  }
  return run;
}

}  // namespace

// ---- Mapping ---------------------------------------------------------------------------------

TEST_CASE("goniometer: mono is vertical, one channel leans to its side, anti-phase is level") {
  const dsp::MapParams params;
  CHECK_POINT(dsp::mapPoint(0, 0, params), 0, 0);
  CHECK_POINT(dsp::mapPoint(0.5f, 0.5f, params), 0, 0.5f);
  CHECK_POINT(dsp::mapPoint(1, 0, params), -0.5f, 0.5f);  // left only: up-left
  CHECK_POINT(dsp::mapPoint(0, 1, params), 0.5f, 0.5f);   // right only: up-right
  CHECK_POINT(dsp::mapPoint(1, -1, params), -1, 0);
  CHECK_POINT(dsp::mapPoint(-1, 1, params), 1, 0);
  CHECK_POINT(dsp::mapPoint(1, 1, params), 0, 1);  // full scale is the unit diamond
  CHECK_POINT(dsp::mapPoint(-1, -1, params), 0, -1);
}

TEST_CASE("gain scales the signal before it is mapped") {
  dsp::MapParams params;
  params.gain = 2;
  CHECK_POINT(dsp::mapPoint(0.25f, 0.25f, params), 0, 0.5f);
  params.scale = dsp::Scale::kLog;  // the log scale sees the gained signal
  CHECK_POINT(dsp::mapPoint(0.5f, 0.5f, params), 0, 1);
}

TEST_CASE("logRadius: full scale is 1, the bottom of the range and below are 0") {
  CHECK(dsp::logRadius(1, 48) == Approx(1));
  CHECK(dsp::logRadius(2, 48) == Approx(1));  // over full scale
  CHECK(dsp::logRadius(dbAmplitude(-12), 48) == Approx(0.75));
  CHECK(dsp::logRadius(dbAmplitude(-48), 48) == Approx(0).epsilon(1e-6));
  CHECK(dsp::logRadius(dbAmplitude(-90), 48) == 0);
  CHECK(dsp::logRadius(0, 48) == 0);
  CHECK(dsp::logRadius(std::numeric_limits<float>::quiet_NaN(), 48) == 0);
}

TEST_CASE("log goniometer: the distance from the center in dB over the range, direction kept") {
  dsp::MapParams params;
  params.scale = dsp::Scale::kLog;
  CHECK_POINT(dsp::mapPoint(1, 1, params), 0, 1);
  const float a24 = dbAmplitude(-24);
  CHECK_POINT(dsp::mapPoint(a24, a24, params), 0, 0.5f);  // halfway down a 48 dB range
  CHECK_POINT(dsp::mapPoint(-a24, -a24, params), 0, -0.5f);
  const float a60 = dbAmplitude(-60);
  CHECK_POINT(dsp::mapPoint(a60, a60, params), 0, 0);
  // Left only at full scale: radius 1/sqrt(2), -3.01 dB, still pointing up-left.
  const float r = 1.0f - 3.0103f / 48.0f;
  CHECK_POINT(dsp::mapPoint(1, 0, params), -r / std::sqrt(2.0f), r / std::sqrt(2.0f));
  params.log_range_db = 24;
  const float a12 = dbAmplitude(-12);
  CHECK_POINT(dsp::mapPoint(a12, a12, params), 0, 0.5f);
}

TEST_CASE("half goniometer: the lower half folds onto the upper, stretched over a 2:1 view") {
  dsp::MapParams params;
  params.half = true;
  CHECK_POINT(dsp::mapPoint(0, 0, params), 0, -1);  // the center is the bottom edge
  CHECK_POINT(dsp::mapPoint(1, 1, params), 0, 1);
  CHECK_POINT(dsp::mapPoint(-1, -1, params), 0, 1);  // folded: the same place
  CHECK_POINT(dsp::mapPoint(-1, 1, params), 1, -1);
  CHECK_POINT(dsp::mapPoint(1, -1, params), -1, -1);
  CHECK_POINT(dsp::mapPoint(0, 1, params), 0.5f, 0);
  CHECK_POINT(dsp::mapPoint(0, -1, params), 0.5f, 0);  // folding keeps the stereo direction
  params.scale = dsp::Scale::kLog;
  const float a24 = dbAmplitude(-24);
  CHECK_POINT(dsp::mapPoint(-a24, -a24, params), 0, 0);  // radius 0.5, folded and stretched
}

TEST_CASE("L/R orientation puts left on X and right on Y; half views stay M/S") {
  dsp::MapParams params;
  params.orientation = dsp::Orientation::kLeftRight;
  CHECK_POINT(dsp::mapPoint(0.3f, -0.7f, params), 0.3f, -0.7f);
  CHECK_POINT(dsp::mapPoint(1, 1, params), 1, 1);  // mono is the diagonal
  params.scale = dsp::Scale::kLog;
  CHECK_POINT(dsp::mapPoint(1, 1, params), 1, 1);
  const float a24 = dbAmplitude(-24);
  CHECK_POINT(dsp::mapPoint(a24, a24, params), 0.5f, 0.5f);

  params.half = true;
  dsp::MapParams mid_side = params;
  mid_side.orientation = dsp::Orientation::kMidSide;
  const dsp::Point expected = dsp::mapPoint(0.3f, -0.7f, mid_side);
  CHECK_POINT(dsp::mapPoint(0.3f, -0.7f, params), expected.x, expected.y);
}

// ---- Color coordinates -----------------------------------------------------------------------

TEST_CASE("amplitude color: the sample's level on the log scale, whatever its direction") {
  CHECK(dsp::amplitudeT(1, 1, 48) == Approx(1));
  const float a24 = dbAmplitude(-24);
  CHECK(dsp::amplitudeT(a24, a24, 48) == Approx(0.5));
  CHECK(dsp::amplitudeT(a24, -a24, 48) == Approx(0.5));
  CHECK(dsp::amplitudeT(0, 0, 48) == 0);
}

TEST_CASE("mid-side color: 0 for mono, 0.5 for one channel, 1 for anti-phase") {
  CHECK(dsp::midSideT(0.5f, 0.5f) == Approx(0));
  CHECK(dsp::midSideT(0.5f, 0) == Approx(0.5));
  CHECK(dsp::midSideT(0, -0.5f) == Approx(0.5));
  CHECK(dsp::midSideT(0.5f, -0.5f) == Approx(1));
  CHECK(dsp::midSideT(0, 0) == 0);
}

TEST_CASE("frequency color: lows near 0, mids in the middle, highs near 1, at any sample rate") {
  for (const double rate : {44100.0, 48000.0, 96000.0, 192000.0}) {
    CAPTURE(rate);
    CHECK(toneColor(60, rate, false) < 0.15f);
    const float mid = toneColor(1000, rate, false);
    CHECK(mid > 0.4f);
    CHECK(mid < 0.7f);
    CHECK(toneColor(8000, rate, false) > 0.85f);
  }
}

TEST_CASE("frequency color: side-only content is colored by its own spectrum") {
  const float high = toneColor(8000, kRate, true);  // anti-phase: no mid signal at all
  CHECK(high > 0.85f);
  CHECK(high == Approx(toneColor(8000, kRate, false)).epsilon(1e-3));
  const float low = toneColor(60, kRate, true);
  CHECK(low >= 0.0f);
  CHECK(low < 0.15f);
}

TEST_CASE("frequency color holds through silence instead of falling to the bass end") {
  dsp::BandColor color;
  color.prepare(kRate);
  float playing = 0;
  for (uint64_t n = 0; n < 24'000; ++n) {
    const float s = 0.5f * sineAt(5000, kRate, n);
    playing = color.process(s, s);
  }
  REQUIRE(playing > 0.8f);
  float silent = 0;
  for (uint64_t n = 0; n < 96'000; ++n) silent = color.process(0, 0);
  CHECK(silent == Approx(playing).epsilon(0.05));
}

// ---- Correlation and balance -----------------------------------------------------------------

TEST_CASE("correlation: +1 for identical channels, -1 for inverted, about 0 for independent noise") {
  dsp::StereoMeter meter;
  meter.prepare(kRate, 0.3);
  Noise a(1);
  Noise b(2);
  feed(meter, 2, [&](uint64_t) {
    const float x = 0.5f * a.next();
    return std::pair{x, x};
  });
  CHECK(meter.correlation() == Approx(1));
  meter.reset();
  feed(meter, 2, [&](uint64_t) {
    const float x = 0.5f * a.next();
    return std::pair{x, -x};
  });
  CHECK(meter.correlation() == Approx(-1));
  meter.reset();
  feed(meter, 2, [&](uint64_t) { return std::pair{0.5f * a.next(), 0.5f * b.next()}; });
  CHECK(std::abs(meter.correlation()) < 0.05f);
}

TEST_CASE("correlation: about 0 for quadrature sines, 0 when either channel is silent") {
  dsp::StereoMeter meter;
  meter.prepare(kRate, 0.3);
  feed(meter, 2, [](uint64_t n) {
    return std::pair{sineAt(1000, kRate, n), sineAt(1000, kRate, n, std::numbers::pi / 2)};
  });
  CHECK(std::abs(meter.correlation()) < 0.01f);
  meter.reset();
  feed(meter, 1, [](uint64_t n) { return std::pair{sineAt(1000, kRate, n), 0.0f}; });
  CHECK(meter.correlation() == 0);
  meter.reset();
  CHECK(meter.correlation() == 0);
}

TEST_CASE("balance: the power ratio, and right over left in dB within +/-60 dB") {
  dsp::StereoMeter meter;
  meter.prepare(kRate, 0.3);
  Noise noise(3);
  const auto run = [&](float left_gain, float right_gain) {
    meter.reset();
    feed(meter, 2, [&](uint64_t) {
      const float x = noise.next();
      return std::pair{left_gain * x, right_gain * x};
    });
  };
  run(0.5f, 0.5f);
  CHECK(meter.balance() == Approx(0));
  CHECK(meter.balanceDb() == Approx(0));
  run(0.5f, 0.25f);  // right at half the amplitude
  CHECK(meter.balance() == Approx(-0.6));
  CHECK(meter.balanceDb() == Approx(-6.0206).epsilon(1e-4));
  run(0.5f, 0);
  CHECK(meter.balance() == Approx(-1));
  CHECK(meter.balanceDb() == Approx(-60));
  run(0, 0.5f);
  CHECK(meter.balance() == Approx(1));
  CHECK(meter.balanceDb() == Approx(60));
  meter.reset();
  CHECK(meter.balance() == 0);
  CHECK(meter.balanceDb() == 0);
}

TEST_CASE("the integration time sets how fast the meters follow, within 50 ms ... 3 s") {
  dsp::StereoMeter fast;
  dsp::StereoMeter slow;
  dsp::StereoMeter beyond;  // asks for 100 s, gets 3 s
  fast.prepare(kRate, 0.05);
  slow.prepare(kRate, 3.0);
  beyond.prepare(kRate, 100.0);
  Noise noise(4);
  const auto run = [&](double seconds, bool inverted) {
    const uint64_t frames = count(seconds, kRate);
    for (uint64_t n = 0; n < frames; ++n) {
      const float x = 0.5f * noise.next();
      for (dsp::StereoMeter* meter : {&fast, &slow, &beyond}) meter->process(x, inverted ? -x : x);
    }
  };
  run(3, false);
  run(0.25, true);
  CHECK(fast.correlation() < -0.9f);
  CHECK(slow.correlation() > 0.5f);
  CHECK(beyond.correlation() == slow.correlation());

  const float before = slow.correlation();
  slow.setIntegration(0.05);  // keeps the averages: no jump
  CHECK(slow.correlation() == before);
  run(0.25, true);
  CHECK(slow.correlation() < -0.9f);  // and follows at the new speed
}

// ---- Auto-gain -------------------------------------------------------------------------------

TEST_CASE("auto-gain brings the peak radius to -3 dB: fast within 3 s, slow within 8 s") {
  dsp::AutoGain fast;
  fast.prepare(kRate);
  fast.setMode(dsp::AutoGainMode::kFast);
  CHECK(autoGainOnTone(fast, 0.1f, 3) == Approx(17).epsilon(0.015));  // -20 dBFS + 17 = -3

  dsp::AutoGain slow;
  slow.prepare(kRate);
  slow.setMode(dsp::AutoGainMode::kSlow);
  CHECK(autoGainOnTone(slow, 0.1f, 1) < 14);  // still on its way after a second
  CHECK(autoGainOnTone(slow, 0.1f, 7) == Approx(17).epsilon(0.015));
}

TEST_CASE("auto-gain stays within -24 ... +36 dB") {
  dsp::AutoGain gain;
  gain.prepare(kRate);
  gain.setMode(dsp::AutoGainMode::kFast);
  CHECK(autoGainOnTone(gain, 0.001f, 3) == Approx(36));  // -60 dBFS would need +57 dB
  CHECK(autoGainOnTone(gain, 20.0f, 3) == Approx(-24));  // +26 dBFS would need -29 dB
}

TEST_CASE("auto-gain holds its gain through silence and noise floors under -72 dBFS") {
  dsp::AutoGain gain;
  gain.prepare(kRate);
  gain.setMode(dsp::AutoGainMode::kFast);
  const float settled = autoGainOnTone(gain, 0.1f, 3);
  REQUIRE(settled == Approx(17).epsilon(0.015));
  CHECK(autoGainOnTone(gain, 0.0f, 10) == Approx(settled).epsilon(1e-4));

  Noise noise(5);  // peaks at -80 dBFS
  float db = 0;
  for (int block = 0; block < 1000; ++block) {
    for (uint32_t k = 0; k < kBlock; ++k) gain.feed(1e-4f * noise.next(), 1e-4f * noise.next());
    db = gain.update(kBlock);
  }
  CHECK(db == Approx(settled).epsilon(1e-4));
  CHECK(autoGainOnTone(gain, 0.1f, 0.5) == Approx(17).epsilon(0.015));  // no catching up to do
}

TEST_CASE("auto-gain starts from the gain it is reset to") {
  dsp::AutoGain gain;
  gain.prepare(kRate);
  gain.setMode(dsp::AutoGainMode::kSlow);
  gain.reset(6);
  CHECK(gain.gainDb() == 6);
  const float after_one_block = autoGainOnTone(gain, 0.1f, kBlock / kRate);
  CHECK(after_one_block > 6);
  CHECK(after_one_block < 6.2f);
  gain.reset(50);
  CHECK(gain.gainDb() == 36);  // within the range
}

TEST_CASE("auto-gain follows the loudest moments, not the average level") {
  dsp::AutoGain gain;
  gain.prepare(kRate);
  gain.setMode(dsp::AutoGainMode::kFast);
  float db = 0;
  uint64_t n = 0;
  for (int beat = 0; beat < 30; ++beat) {  // about 3 s: one loud block, then nine quiet ones
    for (int block = 0; block < 10; ++block) {
      const float amplitude = block == 0 ? 0.5f : 0.05f;
      for (uint32_t k = 0; k < kBlock; ++k, ++n) {
        const float s = amplitude * sineAt(440, kRate, n);
        gain.feed(s, s);
      }
      db = gain.update(kBlock);
    }
  }
  // Set by the -6 dBFS peaks (+3 dB), not by the -26 dBFS rest (+23 dB).
  CHECK(db > 2.5f);
  CHECK(db < 4.5f);
}

TEST_CASE("auto-gain rises again when the music gets quieter, at its mode's pace") {
  const auto check = [](dsp::AutoGainMode mode, double settle_s) {
    dsp::AutoGain gain;
    gain.prepare(kRate);
    gain.setMode(mode);
    REQUIRE(autoGainOnTone(gain, 0.5f, 10) == Approx(3).epsilon(0.015));  // -6 dBFS
    const float after_a_second = autoGainOnTone(gain, 0.05f, 1);         // -26 dBFS: +23 dB
    CHECK(after_a_second > 3.2f);  // on its way up
    CHECK(after_a_second < 12);    // but not in one jump
    CHECK(autoGainOnTone(gain, 0.05f, settle_s) == Approx(23).epsilon(0.015));
  };
  SUBCASE("fast") { check(dsp::AutoGainMode::kFast, 5); }
  SUBCASE("slow") { check(dsp::AutoGainMode::kSlow, 15); }
}

// ---- Analyzer --------------------------------------------------------------------------------

TEST_CASE("analyzer: one point per frame with the manual gain, and the meters") {
  dsp::Analyzer analyzer;
  dsp::AnalyzerConfig config;
  config.map.gain = 2;
  config.color = dsp::ColorMode::kSolid;
  analyzer.configure(config);
  analyzer.prepare(kRate);
  const std::vector<float> frames = {0.25f, 0.25f, 0.5f, 0.0f, 0.1f, -0.1f};
  std::vector<dsp::Point> points(3);
  std::vector<float> color(3, -1.0f);
  analyzer.process(frames.data(), 3, points.data(), color.data());
  CHECK_POINT(points[0], 0, 0.5f);
  CHECK_POINT(points[1], -0.5f, 0.5f);
  CHECK_POINT(points[2], -0.2f, 0);
  CHECK(color == std::vector<float>(3, 0.0f));  // solid: no color coordinate
  CHECK(analyzer.gainDb() == Approx(6.0206).epsilon(1e-4));

  analyzer.process(frames.data(), 0, points.data(), color.data());  // nothing to do
  analyzer.reset();
  runAnalyzer(analyzer, 1, [](uint64_t n) {
    const float s = 0.5f * sineAt(440, kRate, n);
    return std::pair{s, 0.5f * s};
  });
  CHECK(analyzer.correlation() == Approx(1));
  CHECK(analyzer.balance() == Approx(-0.6));
  CHECK(analyzer.balanceDb() == Approx(-6.0206).epsilon(1e-4));
}

TEST_CASE("analyzer: color modes give frequency, level or mid-side coordinates") {
  dsp::Analyzer analyzer;
  analyzer.prepare(kRate);
  dsp::AnalyzerConfig config;
  // Left only, at -24 dBFS. 1 kHz at 48 kHz has a sample on every peak.
  const auto tone = [](double frequency) {
    return [frequency](uint64_t n) {
      return std::pair{dbAmplitude(-24) * sineAt(frequency, kRate, n), 0.0f};
    };
  };

  config.color = dsp::ColorMode::kFrequency;
  analyzer.configure(config);
  AnalyzerRun run = runAnalyzer(analyzer, 0.5, tone(8000));
  CHECK(run.color.back() > 0.85f);

  config.color = dsp::ColorMode::kMidSide;
  analyzer.configure(config);
  run = runAnalyzer(analyzer, 0.1, [](uint64_t) { return std::pair{0.25f, 0.0f}; });
  for (const float t : run.color) CHECK(t == Approx(0.5));
  run = runAnalyzer(analyzer, 0.1, [](uint64_t) { return std::pair{0.25f, -0.25f}; });
  CHECK(run.color.back() == Approx(1));

  config.color = dsp::ColorMode::kAmplitude;
  config.map.gain = 2;  // the color follows the displayed level
  analyzer.configure(config);
  run = runAnalyzer(analyzer, 0.1, tone(1000));
  float brightest = 0;
  for (const float t : run.color) brightest = std::max(brightest, t);
  // Peak radius: -24 dBFS, +6 dB of gain, -3 dB for one channel: -21 dB of a 48 dB range.
  CHECK(brightest == Approx(1 - 21.0 / 48).epsilon(0.01));
}

TEST_CASE("analyzer: non-finite samples count as silence and huge ones stay finite") {
  dsp::Analyzer analyzer;
  analyzer.prepare(kRate);
  dsp::AnalyzerConfig config;
  config.map.scale = dsp::Scale::kLog;
  analyzer.configure(config);
  constexpr float kInf = std::numeric_limits<float>::infinity();
  const std::vector<float> frames = {std::numeric_limits<float>::quiet_NaN(), 0.5f, kInf, -kInf,
                                     1e30f, -1e30f, 0.5f, 0.5f};
  std::vector<dsp::Point> points(4);
  std::vector<float> color(4);
  analyzer.process(frames.data(), 4, points.data(), color.data());
  for (size_t i = 0; i < points.size(); ++i) {
    CAPTURE(i);
    CHECK(std::isfinite(points[i].x));
    CHECK(std::isfinite(points[i].y));
    CHECK(std::isfinite(color[i]));
  }
  CHECK_POINT(points[1], 0, 0);   // both infinite: silence
  CHECK_POINT(points[2], -1, 0);  // huge anti-phase: full scale, pointing left
  CHECK(std::isfinite(analyzer.correlation()));
  CHECK(std::isfinite(analyzer.balance()));
  CHECK(std::isfinite(analyzer.balanceDb()));
}

TEST_CASE("analyzer: auto-gain replaces the manual gain, starting from it") {
  dsp::Analyzer analyzer;
  analyzer.prepare(kRate);
  dsp::AnalyzerConfig config;
  config.map.gain = 2;  // +6.02 dB
  analyzer.configure(config);
  config.auto_gain = dsp::AutoGainMode::kFast;
  analyzer.configure(config);
  const auto tone = [](uint64_t n) {
    const float s = 0.1f * sineAt(440, kRate, n);
    return std::pair{s, s};
  };
  runAnalyzer(analyzer, kBlock / kRate, tone);
  CHECK(analyzer.gainDb() > 6.0f);
  CHECK(analyzer.gainDb() < 8.0f);
  const AnalyzerRun run = runAnalyzer(analyzer, 3, tone);
  CHECK(analyzer.gainDb() == Approx(17).epsilon(0.015));
  float peak = 0;
  for (const dsp::Point& p : run.points) peak = std::max(peak, std::hypot(p.x, p.y));
  CHECK(peak == Approx(dbAmplitude(-3)).epsilon(0.02));

  config.auto_gain = dsp::AutoGainMode::kOff;
  analyzer.configure(config);
  runAnalyzer(analyzer, kBlock / kRate, tone);
  CHECK(analyzer.gainDb() == Approx(6.0206).epsilon(1e-4));  // back to the manual gain
}

TEST_CASE("analyzer: settings outside their ranges are clamped") {
  constexpr float kNaN = std::numeric_limits<float>::quiet_NaN();
  dsp::Analyzer analyzer;
  analyzer.prepare(kRate);
  dsp::AnalyzerConfig config;
  config.map.gain = 1000;  // +60 dB
  analyzer.configure(config);
  CHECK(analyzer.gainDb() == Approx(36));
  config.map.gain = 0;
  analyzer.configure(config);
  CHECK(analyzer.gainDb() == Approx(-24));
  config.map.gain = kNaN;  // unusable: unity gain
  analyzer.configure(config);
  CHECK(analyzer.gainDb() == 0);

  // The log range: 10 dB acts as 24 dB, 1000 dB as 72 dB, and NaN as the default 48 dB.
  config.map.gain = 1;
  config.map.scale = dsp::Scale::kLog;
  config.color = dsp::ColorMode::kSolid;
  const auto mono_point = [&](float range_db, double level_db) {
    config.map.log_range_db = range_db;
    analyzer.configure(config);
    const float a = dbAmplitude(level_db);
    const std::vector<float> frame = {a, a};
    dsp::Point point;
    float t = 0;
    analyzer.process(frame.data(), 1, &point, &t);
    return point;
  };
  CHECK_POINT(mono_point(10, -12), 0, 0.5f);
  CHECK_POINT(mono_point(1000, -36), 0, 0.5f);
  CHECK_POINT(mono_point(kNaN, -24), 0, 0.5f);
}

TEST_CASE("analyzer: an integration time outside 50 ms ... 3 s is clamped, NaN is the default") {
  for (const auto [asked, used] : {std::pair{0.0, dsp::kMinIntegrationS},
                                   std::pair{-1.0, dsp::kMinIntegrationS},
                                   std::pair{1e9, dsp::kMaxIntegrationS},
                                   std::pair{std::numeric_limits<double>::quiet_NaN(),
                                             dsp::kDefaultIntegrationS}}) {
    CAPTURE(asked);
    dsp::Analyzer analyzer;
    dsp::AnalyzerConfig config;
    config.integration_s = asked;
    analyzer.configure(config);
    analyzer.prepare(kRate);
    dsp::StereoMeter meter;
    meter.prepare(kRate, used);
    Noise noise(6);
    runAnalyzer(analyzer, 1, [&](uint64_t n) {
      const float x = 0.5f * noise.next();
      const std::pair frame{x, n < 36'000 ? x : -x};  // identical, then inverted
      meter.process(frame.first, frame.second);
      return frame;
    });
    CHECK(analyzer.correlation() == meter.correlation());
    CHECK(analyzer.correlation() >= -1);
    CHECK(analyzer.correlation() <= 1);
  }
}

TEST_CASE("analyzer: a sample rate it cannot use still gives finite output") {
  for (const double rate : {0.0, -48000.0, 100.0, 1e9, std::numeric_limits<double>::quiet_NaN(),
                            std::numeric_limits<double>::infinity()}) {
    CAPTURE(rate);
    dsp::Analyzer analyzer;
    analyzer.prepare(rate);
    dsp::AnalyzerConfig config;
    config.auto_gain = dsp::AutoGainMode::kFast;
    analyzer.configure(config);
    const AnalyzerRun run = runAnalyzer(analyzer, 0.1, [](uint64_t n) {
      const float s = 0.5f * sineAt(1000, kRate, n);
      return std::pair{s, 0.25f * s};
    });
    bool finite = true;
    bool in_range = true;
    for (size_t i = 0; i < run.points.size(); ++i) {
      finite = finite && std::isfinite(run.points[i].x) && std::isfinite(run.points[i].y);
      in_range = in_range && run.color[i] >= 0 && run.color[i] <= 1;
    }
    CHECK(finite);
    CHECK(in_range);
    CHECK(analyzer.correlation() == Approx(1));  // the same shape on both channels
    CHECK(analyzer.balanceDb() == Approx(-12.0412).epsilon(1e-4));
    CHECK(analyzer.gainDb() >= dsp::kMinGainDb);
    CHECK(analyzer.gainDb() <= dsp::kMaxGainDb);
  }
}
