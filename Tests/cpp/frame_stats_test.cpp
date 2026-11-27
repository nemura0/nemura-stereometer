#include <nmr/frame_stats.h>

#include <doctest/doctest.h>

#include <limits>

namespace {

using nmr::FrameStats;

constexpr double kPeriod = 1.0 / 120;
constexpr double kPeriodMs = 1000.0 / 120;
constexpr double kBin = FrameStats::kBinMs;

// `count` frames presented one period apart after `start`; returns the last one's time.
double steady(FrameStats& stats, double start, int count) {
  double t = start;
  for (int i = 0; i < count; ++i) {
    t += kPeriod;
    stats.frame(t, kPeriod);
  }
  return t;
}

}  // namespace

TEST_CASE("frame stats: steady frames drop nothing and sit on the period") {
  FrameStats stats;
  steady(stats, 10, 1000);
  const auto s = stats.summary();
  CHECK(s.frames == 1000);
  CHECK(s.presented == 1000);
  CHECK(s.dropped == 0);
  CHECK(s.intervals == 999);
  CHECK(s.period_ms == doctest::Approx(kPeriodMs));
  CHECK(s.p1_ms == doctest::Approx(kPeriodMs).epsilon(kBin / kPeriodMs));
  CHECK(s.p50_ms == doctest::Approx(kPeriodMs).epsilon(kBin / kPeriodMs));
  CHECK(s.p99_ms == doctest::Approx(kPeriodMs).epsilon(kBin / kPeriodMs));
  CHECK(s.max_ms == doctest::Approx(kPeriodMs));
}

TEST_CASE("frame stats: a skipped display period is a dropped frame") {
  FrameStats stats;
  double t = steady(stats, 10, 500);
  t += 2 * kPeriod;  // one vsync with no new frame
  stats.frame(t, kPeriod);
  t += 4 * kPeriod;  // three of them
  stats.frame(t, kPeriod);
  steady(stats, t, 500);
  const auto s = stats.summary();
  CHECK(s.dropped == 4);
  CHECK(s.max_ms == doctest::Approx(4 * kPeriodMs));
  CHECK(s.p99_ms == doctest::Approx(kPeriodMs).epsilon(kBin / kPeriodMs));  // rare: not p99
}

TEST_CASE("frame stats: a frame never presented is dropped once, not again in the gap") {
  FrameStats stats;
  double t = steady(stats, 10, 100);
  stats.frame(0, kPeriod);  // its drawable never reached the screen
  t += 2 * kPeriod;
  stats.frame(t, kPeriod);
  steady(stats, t, 100);
  const auto s = stats.summary();
  CHECK(s.frames == 202);
  CHECK(s.presented == 201);
  CHECK(s.dropped == 1);
  CHECK(s.intervals == 199);  // none across the dropped frame
}

TEST_CASE("frame stats: a pause (idle, hidden) is not dropped frames") {
  FrameStats stats;
  double t = steady(stats, 10, 100);
  t += 2.0;
  stats.frame(t, kPeriod);
  steady(stats, t, 100);
  const auto s = stats.summary();
  CHECK(s.dropped == 0);
  CHECK(s.intervals == 199);  // 99 before, none across, 100 after
  CHECK(s.max_ms == doctest::Approx(kPeriodMs));
}

TEST_CASE("frame stats: uneven frames show in the percentiles") {
  FrameStats stats;
  double t = 10;
  for (int i = 0; i < 1000; ++i) {
    t += (i % 2 == 0) ? kPeriod - 0.002 : kPeriod + 0.002;
    stats.frame(t, kPeriod);
  }
  const auto s = stats.summary();
  CHECK(s.dropped == 0);
  CHECK(s.p1_ms == doctest::Approx(kPeriodMs - 2).epsilon(kBin / kPeriodMs));
  CHECK(s.p99_ms == doctest::Approx(kPeriodMs + 2).epsilon(kBin / kPeriodMs));
}

TEST_CASE("frame stats: a new period starts a new chain") {
  FrameStats stats;
  double t = steady(stats, 10, 100);
  t += 1.0 / 60;
  stats.frame(t, 1.0 / 60);  // stepped down to 60 Hz: one 60 Hz period, not a skipped frame
  const auto s = stats.summary();
  CHECK(s.dropped == 0);
  CHECK(s.intervals == 99);
  CHECK(s.period_ms == doctest::Approx(1000.0 / 60));
}

TEST_CASE("frame stats: bad times count as not presented") {
  FrameStats stats;
  const double t = steady(stats, 10, 10);
  stats.frame(std::numeric_limits<double>::quiet_NaN(), kPeriod);
  stats.frame(t - 1, kPeriod);  // before the previous one
  stats.frame(t + kPeriod, std::numeric_limits<double>::infinity());
  const auto s = stats.summary();
  CHECK(s.frames == 13);
  CHECK(s.presented == 10);
  CHECK(s.dropped == 3);
  CHECK(s.intervals == 9);
}

TEST_CASE("frame stats: an interval past the histogram keeps its exact maximum") {
  FrameStats stats;
  stats.frame(1.0, 0.2);
  stats.frame(1.2, 0.2);  // 200 ms: beyond the 100 ms histogram, within kMaxGapS
  const auto s = stats.summary();
  CHECK(s.intervals == 1);
  CHECK(s.max_ms == doctest::Approx(200));
  CHECK(s.p99_ms == doctest::Approx(FrameStats::kBins * kBin).epsilon(0.01));
}

TEST_CASE("frame stats: reset forgets everything") {
  FrameStats stats;
  steady(stats, 10, 50);
  stats.reset();
  const auto s = stats.summary();
  CHECK(s.frames == 0);
  CHECK(s.intervals == 0);
  CHECK(s.p99_ms == 0);
  CHECK(s.max_ms == 0);
}

TEST_CASE("frame stats: each frame's CPU and GPU time, and the ones over their period") {
  FrameStats stats;
  stats.work(0.001, 0.002, kPeriod);
  stats.work(0.004, 0.005, kPeriod);  // 9 ms: over an 8.3 ms period
  stats.work(0.0005, 0.0005, kPeriod);
  stats.work(std::numeric_limits<double>::quiet_NaN(), 0.001, kPeriod);  // not counted
  const auto s = stats.summary();
  CHECK(s.worked == 3);
  CHECK(s.cpu_max_ms == doctest::Approx(4));
  CHECK(s.gpu_max_ms == doctest::Approx(5));
  CHECK(s.over_period == 1);
  CHECK(s.cpu_p99_ms == doctest::Approx(4).epsilon(0.02));
  CHECK(s.gpu_p99_ms == doctest::Approx(5).epsilon(0.02));
  stats.reset();
  CHECK(stats.summary().worked == 0);
}
