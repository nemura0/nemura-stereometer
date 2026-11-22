#include <nmr/frame_rate.h>

#include <doctest/doctest.h>

#include <cmath>

namespace {

using nmr::FrameRateChoice;
using nmr::FrameRateGovernor;

// `seconds` of frames at `hz` after `start`, every `late_every`-th one late (0: none).
// Returns the last frame's time.
double run(FrameRateGovernor& governor, double start, double seconds, double hz,
           int late_every) {
  const int frames = static_cast<int>(seconds * hz);
  for (int f = 1; f <= frames; ++f) {
    governor.frame(start + f / hz, late_every > 0 && f % late_every == 0);
  }
  return start + frames / hz;
}

}  // namespace

TEST_CASE("frame rate: Auto runs at the display's maximum") {
  FrameRateGovernor governor;
  governor.configure(FrameRateChoice::kAuto, 120);
  CHECK(governor.rate() == 120);
  governor.configure(FrameRateChoice::kAuto, 60);
  CHECK(governor.rate() == 60);
  governor.configure(FrameRateChoice::kAuto, 144);
  CHECK(governor.rate() == 144);
  for (double bad : {0.0, -1.0, std::nan(""), HUGE_VAL}) {
    governor.configure(FrameRateChoice::kAuto, bad);
    CHECK(governor.rate() == FrameRateGovernor::kDefaultDisplayHz);
  }
  CHECK_FALSE(governor.steppedDown());
}

TEST_CASE("frame rate: a forced rate never goes above the display") {
  FrameRateGovernor governor;
  governor.configure(FrameRateChoice::k120, 120);
  CHECK(governor.rate() == 120);
  governor.configure(FrameRateChoice::k120, 60);
  CHECK(governor.rate() == 60);
  governor.configure(FrameRateChoice::k60, 120);
  CHECK(governor.rate() == 60);
  governor.configure(FrameRateChoice::k30, 120);
  CHECK(governor.rate() == 30);
  governor.configure(FrameRateChoice::k30, 24);
  CHECK(governor.rate() == 24);
}

TEST_CASE("frame rate: Auto steps down to 60 when more than 1 % of 2 s is late") {
  FrameRateGovernor governor;
  governor.configure(FrameRateChoice::kAuto, 120);
  run(governor, 100, 5, 120, 130);  // under 1 % (at most 2 in the window): stays
  CHECK(governor.rate() == 120);
  CHECK_FALSE(governor.steppedDown());
  governor.configure(FrameRateChoice::kAuto, 120);
  const double time = run(governor, 0, 1.9, 120, 40);  // 2.5 %, but not yet 2 s of it
  CHECK(governor.rate() == 120);
  run(governor, time, 0.5, 120, 40);
  CHECK(governor.rate() == 60);
  CHECK(governor.steppedDown());
}

TEST_CASE("frame rate: late frames older than 2 s are forgotten") {
  FrameRateGovernor governor;
  governor.configure(FrameRateChoice::kAuto, 120);
  double time = run(governor, 0, 2.2, 120, 0);
  for (int f = 0; f < 2; ++f) governor.frame(time += 1.0 / 120, true);
  time = run(governor, time, 2.2, 120, 0);
  // Two late frames in any 2 s is under 1 % of 240; three would not be.
  for (int f = 0; f < 2; ++f) governor.frame(time += 1.0 / 120, true);
  run(governor, time, 1, 120, 0);
  CHECK(governor.rate() == 120);
  governor.configure(FrameRateChoice::kAuto, 120);
  time = run(governor, 0, 2.5, 120, 0);
  for (int f = 0; f < 3; ++f) governor.frame(time += 1.0 / 120, true);
  CHECK(governor.rate() == 60);
}

TEST_CASE("frame rate: a start or restart waits for 2 s of frames after a rough 250 ms") {
  FrameRateGovernor governor;
  governor.configure(FrameRateChoice::kAuto, 120);
  double time = 0;
  for (int f = 0; f < 29; ++f) governor.frame(time += 1.0 / 120, true);  // a rough start
  time = run(governor, time, 1.8, 120, 0);
  CHECK(governor.rate() == 120);
  time = run(governor, time, 3, 120, 0);
  CHECK(governor.rate() == 120);
  governor.restart();  // the link stopped and starts again
  for (int f = 0; f < 10; ++f) governor.frame(time += 1.0 / 120, true);
  CHECK(governor.rate() == 120);
}

TEST_CASE("frame rate: only Auto steps down, only from above 60, until configured again") {
  FrameRateGovernor governor;
  for (FrameRateChoice choice : {FrameRateChoice::k120, FrameRateChoice::k60}) {
    governor.configure(choice, 120);
    const double before = governor.rate();
    run(governor, 0, 4, before, 10);
    CHECK(governor.rate() == before);
    CHECK_FALSE(governor.steppedDown());
  }
  governor.configure(FrameRateChoice::kAuto, 60);
  run(governor, 0, 4, 60, 10);
  CHECK(governor.rate() == 60);
  CHECK_FALSE(governor.steppedDown());
  governor.configure(FrameRateChoice::kAuto, 120);
  double time = run(governor, 0, 4, 120, 10);
  CHECK(governor.steppedDown());
  run(governor, time, 10, 60, 0);  // smooth at 60: it stays there
  CHECK(governor.rate() == 60);
  governor.configure(FrameRateChoice::kAuto, 120);
  CHECK(governor.rate() == 120);
  CHECK_FALSE(governor.steppedDown());
}

TEST_CASE("frame rate: 2 late frames of 200 stay, a third steps down") {
  FrameRateGovernor governor;
  governor.configure(FrameRateChoice::kAuto, 100);
  int f = 0;
  for (; f < 400; ++f) governor.frame((f + 0.5) / 100, f == 310 || f == 350);
  CHECK(governor.rate() == 100);
  governor.frame((f + 0.5) / 100, true);
  CHECK(governor.rate() == 60);
}

TEST_CASE("frame rate: frames the link never delivered count as late") {
  FrameRateGovernor governor;
  governor.configure(FrameRateChoice::kAuto, 120);
  double time = run(governor, 10, 3, 120, 0);
  for (int f = 0; f < 240 && governor.rate() == 120; ++f) {
    time += (f % 40 == 39 ? 2.0 : 1.0) / 120;  // every 40th frame never came (2.5 %)
    governor.frame(time, false);
  }
  CHECK(governor.rate() == 60);
}

TEST_CASE("frame rate: a pause longer than 250 ms is no missed frames") {
  FrameRateGovernor governor;
  governor.configure(FrameRateChoice::kAuto, 120);
  double time = run(governor, 10, 3, 120, 0);
  for (int pause = 0; pause < 5; ++pause) time = run(governor, time + 0.3, 2.5, 120, 0);
  CHECK(governor.rate() == 120);
  // A shorter one is: 0.2 s at 120 Hz is 23 frames that never came.
  run(governor, time + 0.2, 0.1, 120, 0);
  CHECK(governor.rate() == 60);
}

TEST_CASE("frame rate: late frames from before a pause in the frames are forgotten") {
  FrameRateGovernor governor;
  governor.configure(FrameRateChoice::kAuto, 120);
  double time = run(governor, 10, 2.2, 120, 0);
  for (int f = 0; f < 2; ++f) governor.frame(time += 1.0 / 120, true);
  // No frames for 3 s (the caller did not restart), then smooth ones and two late again.
  time = run(governor, time + 3, 1, 120, 0);
  for (int f = 0; f < 2; ++f) governor.frame(time += 1.0 / 120, true);
  CHECK(governor.rate() == 120);
}

TEST_CASE("frame rate: a frame whose time goes back counts at the last time") {
  FrameRateGovernor governor;
  governor.configure(FrameRateChoice::kAuto, 120);
  double time = run(governor, 10, 3, 120, 0);
  for (int f = 0; f < 2; ++f) governor.frame(time += 1.0 / 120, true);
  governor.frame(time - 2, false);  // counted at `time`, not 2 s back
  governor.frame(time - 2, true);
  CHECK(governor.rate() == 60);
}

TEST_CASE("frame rate: ignores frames whose time is not a number") {
  FrameRateGovernor governor;
  governor.configure(FrameRateChoice::kAuto, 120);
  run(governor, 10, 3, 120, 0);
  for (int f = 0; f < 50; ++f) governor.frame(std::nan(""), true);
  CHECK(governor.rate() == 120);
}

TEST_CASE("frame rate: a restart with a clock that starts lower forgets the old frames") {
  FrameRateGovernor governor;
  governor.configure(FrameRateChoice::kAuto, 120);
  // Late frames counted but not yet decided on (past the warm-up, before 2 s of frames).
  const double time = run(governor, 100, 0.5, 120, 0);
  for (int f = 1; f <= 30; ++f) governor.frame(time + f / 120.0, true);
  CHECK(governor.rate() == 120);
  governor.restart();
  run(governor, 0, 5, 120, 0);
  CHECK(governor.rate() == 120);
}

TEST_CASE("frame rate: holds a display rate to 1000 Hz and ignores absurd times") {
  FrameRateGovernor governor;
  governor.configure(FrameRateChoice::kAuto, 1e12);
  CHECK(governor.rate() == FrameRateGovernor::kMaxDisplayHz);
  governor.frame(1, false);
  governor.frame(1.2, false);  // 199 frames that never came
  CHECK(governor.rate() == FrameRateGovernor::kMaxDisplayHz);
  governor.configure(FrameRateChoice::kAuto, 120);
  run(governor, 10, 3, 120, 0);
  for (double time : {1e300, 9.3e17}) governor.frame(time, true);
  run(governor, 13, 1, 120, 0);
  CHECK(governor.rate() == 120);
}
