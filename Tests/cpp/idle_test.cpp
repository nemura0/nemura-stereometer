#include <nmr/idle.h>

#include <doctest/doctest.h>

#include <cmath>
#include <limits>
#include <vector>

using nmr::IdleDetector;

namespace {
constexpr double kFrame = 1.0 / 120;
}

TEST_CASE("idle: stops after silence longer than the trail time + 250 ms") {
  IdleDetector idle;
  idle.prepare(0.1);
  int f = 0;
  for (; f < 120; ++f) CHECK_FALSE(idle.frame(f * kFrame, true));
  const double last_sound = (f - 1) * kFrame;
  bool stopped = false;
  for (; !stopped && f < 1000; ++f) stopped = idle.frame(f * kFrame, false);
  CHECK(stopped);
  CHECK(idle.idle());
  const double stopped_at = (f - 1) * kFrame;
  CHECK(stopped_at - last_sound > 0.35);
  CHECK(stopped_at - last_sound <= 0.35 + kFrame + 1e-9);
}

TEST_CASE("idle: counts silence from the first frame, and any sound starts it again") {
  IdleDetector idle;
  idle.prepare(1.0);
  double time = 50;
  for (int f = 0; f < 100; ++f) CHECK_FALSE(idle.frame(time += kFrame, false));  // 0.83 s
  CHECK_FALSE(idle.frame(time += kFrame, true));
  for (int f = 0; f < 140; ++f) CHECK_FALSE(idle.frame(time += kFrame, false));  // 1.17 s
  bool stopped = false;
  for (int f = 0; !stopped && f < 20; ++f) stopped = idle.frame(time += kFrame, false);
  CHECK(stopped);
}

TEST_CASE("idle: tells to stop once, then wakes on sound") {
  IdleDetector idle;
  idle.prepare(0);
  double time = 0;
  int stops = 0;
  for (int f = 0; f < 120; ++f) stops += idle.frame(time += kFrame, false) ? 1 : 0;
  CHECK(stops == 1);
  CHECK(idle.idle());
  idle.wake(time += 1);
  CHECK_FALSE(idle.idle());
  // Awake again: silence counts from the wake.
  for (int f = 0; f < 30; ++f) CHECK_FALSE(idle.frame(time += kFrame, false));
}

TEST_CASE("idle: a new trail time applies at once") {
  IdleDetector idle;
  idle.prepare(1.0);
  double time = 0;
  CHECK_FALSE(idle.frame(time, true));
  for (int f = 0; f < 60; ++f) CHECK_FALSE(idle.frame(time += kFrame, false));  // 0.5 s
  idle.setTrail(0.1);
  CHECK(idle.frame(time += kFrame, false));
}

TEST_CASE("idle: a trail that is not a number, infinite or negative counts as 0") {
  for (double trail : {-1.0, std::nan(""), -HUGE_VAL, HUGE_VAL}) {
    CAPTURE(trail);
    IdleDetector idle;
    idle.prepare(trail);
    double time = 0;
    int f = 0;
    while (!idle.frame(time, false)) time = ++f * kFrame;
    CHECK(time > IdleDetector::kHoldS);
    CHECK(time <= IdleDetector::kHoldS + kFrame);
  }
}

TEST_CASE("idle: no trail lasts more than 10 s") {
  IdleDetector idle;
  idle.prepare(1e9);
  double time = 0;
  int f = 0;
  while (!idle.frame(time, false) && f < 10000) time = ++f * kFrame;
  CHECK(time > IdleDetector::kMaxTrailS + IdleDetector::kHoldS);
  CHECK(time <= IdleDetector::kMaxTrailS + IdleDetector::kHoldS + kFrame);
}

TEST_CASE("idle: what counts as sound") {
  std::vector<float> frames(2 * 256, 0.0f);
  CHECK_FALSE(IdleDetector::hasSound(frames.data(), 256));
  CHECK_FALSE(IdleDetector::hasSound(nullptr, 256));
  CHECK_FALSE(IdleDetector::hasSound(frames.data(), 0));
  frames[511] = 2e-5f;  // the last right sample
  CHECK(IdleDetector::hasSound(frames.data(), 256));
  CHECK_FALSE(IdleDetector::hasSound(frames.data(), 255));
  frames[511] = -2e-5f;
  CHECK(IdleDetector::hasSound(frames.data(), 256));
  frames[511] = IdleDetector::kSilence;
  CHECK_FALSE(IdleDetector::hasSound(frames.data(), 256));
  frames[511] = std::numeric_limits<float>::quiet_NaN();
  frames[0] = std::numeric_limits<float>::infinity();
  CHECK_FALSE(IdleDetector::hasSound(frames.data(), 256));
  frames[300] = 0.5f;
  CHECK(IdleDetector::hasSound(frames.data(), 256));
}

TEST_CASE("idle: ignores a time that is not a number; one that goes back counts at the last") {
  IdleDetector idle;
  idle.prepare(0.1);
  double time = 10;
  CHECK_FALSE(idle.frame(time, false));
  for (int f = 0; f < 20; ++f) CHECK_FALSE(idle.frame(std::nan(""), false));
  CHECK_FALSE(idle.frame(time += 0.3, false));
  CHECK_FALSE(idle.frame(time - 5, true));  // sound, at 10.3
  CHECK_FALSE(idle.frame(time += 0.3, false));
  CHECK(idle.frame(time += 0.1, false));
}

TEST_CASE("idle: a first time below zero counts like any other") {
  IdleDetector idle;
  idle.prepare(0.1);
  CHECK_FALSE(idle.frame(-5, false));
  CHECK_FALSE(idle.frame(-4.7, false));
  CHECK(idle.frame(-4.6, false));
}

TEST_CASE("idle: a wake whose time is not a number changes nothing; sound while idle is not") {
  IdleDetector idle;
  idle.prepare(0);
  double time = 0;
  while (!idle.frame(time, false)) time += kFrame;
  CHECK_FALSE(idle.frame(time += kFrame, true));  // stopped frames do not wake it: wake() does
  CHECK(idle.idle());
  idle.wake(std::nan(""));
  CHECK(idle.idle());
  idle.wake(time - 1);  // a time in the past wakes it at the last time
  CHECK_FALSE(idle.idle());
  CHECK_FALSE(idle.frame(time + 0.2, false));
  CHECK(idle.frame(time + 0.3, false));
}
