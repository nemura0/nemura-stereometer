#include <nmr/frame_ring.h>
#include <nmr/signal_watch.h>

#include <doctest/doctest.h>

#include <limits>
#include <vector>

using nmr::Samples;
using nmr::Signal;
using nmr::SignalWatch;

namespace {
constexpr double kStep = SignalWatch::kCheckS;

// Checks every kStep from `from` to `to` (inclusive) and returns the last signal.
Signal run(SignalWatch& watch, double from, double to, Samples samples, bool others_playing) {
  Signal last = watch.signal();
  for (double t = from; t <= to + 1e-9; t += kStep) last = watch.check(t, samples, others_playing);
  return last;
}

constexpr Samples kZeros = Samples::kZeros;
constexpr Samples kSound = Samples::kSound;
constexpr Samples kNone = Samples::kNone;
}  // namespace

TEST_CASE("signal watch: starts unknown, and sound means the grant works") {
  SignalWatch watch;
  CHECK(watch.signal() == Signal::kUnknown);
  CHECK_FALSE(watch.done());
  CHECK(watch.check(0, kSound, true) == Signal::kSound);
  CHECK(watch.done());
  // Sound is never taken back: later zeros are just silence.
  CHECK(run(watch, kStep, 20, kZeros, true) == Signal::kSound);
}

TEST_CASE("signal watch: sound seen in an earlier run needs no watching") {
  SignalWatch watch(true);
  CHECK(watch.signal() == Signal::kSound);
  CHECK(watch.done());
  CHECK(watch.check(0, kZeros, true) == Signal::kSound);
}

TEST_CASE("signal watch: zeros while another process plays for kSuspectS look denied") {
  SignalWatch watch;
  CHECK(run(watch, 0, SignalWatch::kSuspectS - kStep, kZeros, true) == Signal::kUnknown);
  CHECK(watch.check(SignalWatch::kSuspectS, kZeros, true) == Signal::kSilenceWhilePlaying);
  CHECK_FALSE(watch.done());
}

TEST_CASE("signal watch: zeros while nothing plays are just silence") {
  SignalWatch watch;
  CHECK(run(watch, 0, 60, kZeros, false) == Signal::kUnknown);
}

TEST_CASE("signal watch: the playing time starts again when the other process stops") {
  SignalWatch watch;
  run(watch, 0, 3, kZeros, true);
  watch.check(3.5, kZeros, false);
  CHECK(run(watch, 4, 4 + SignalWatch::kSuspectS - kStep, kZeros, true) == Signal::kUnknown);
  CHECK(watch.check(4 + SignalWatch::kSuspectS, kZeros, true) == Signal::kSilenceWhilePlaying);
}

TEST_CASE("signal watch: a suspicion holds until sound arrives") {
  SignalWatch watch;
  run(watch, 0, SignalWatch::kSuspectS, kZeros, true);
  REQUIRE(watch.signal() == Signal::kSilenceWhilePlaying);
  CHECK(run(watch, 5, 10, kZeros, false) == Signal::kSilenceWhilePlaying);
  CHECK(watch.check(10.5, kSound, false) == Signal::kSound);
  CHECK(watch.done());
}

TEST_CASE("signal watch: times that are not numbers or go back change nothing") {
  SignalWatch watch;
  run(watch, 0, 2, kZeros, true);
  const double nan = std::numeric_limits<double>::quiet_NaN();
  const double inf = std::numeric_limits<double>::infinity();
  CHECK(watch.check(nan, kZeros, true) == Signal::kUnknown);
  CHECK(watch.check(inf, kZeros, true) == Signal::kUnknown);
  // Playing stops at 2.5, then starts again at a time back in the past: it counts at 2.5, so
  // the playing time starts there, not 102.5 s earlier.
  CHECK(watch.check(2.5, kZeros, false) == Signal::kUnknown);
  CHECK(watch.check(-100, kZeros, true) == Signal::kUnknown);
  CHECK(watch.check(2.5 + SignalWatch::kSuspectS - 0.1, kZeros, true) == Signal::kUnknown);
  CHECK(watch.check(2.5 + SignalWatch::kSuspectS, kZeros, true) ==
        Signal::kSilenceWhilePlaying);
  // A non-number time still takes sound: it carries no timing.
  SignalWatch other;
  CHECK(other.check(nan, kSound, false) == Signal::kSound);
}

TEST_CASE("signal watch: a look with no frames is no evidence, and starts the time again") {
  SignalWatch watch;
  // A stalled tap delivers nothing: that is not the zeros of a denied grant.
  CHECK(run(watch, 0, 20, kNone, true) == Signal::kUnknown);
  run(watch, 20.5, 23, kZeros, true);
  watch.check(23.5, kNone, true);
  CHECK(run(watch, 24, 24 + SignalWatch::kSuspectS - kStep, kZeros, true) == Signal::kUnknown);
  CHECK(watch.check(24 + SignalWatch::kSuspectS, kZeros, true) ==
        Signal::kSilenceWhilePlaying);
}

TEST_CASE("signal watch: a new tap starts the playing time again") {
  SignalWatch watch;
  run(watch, 0, 3.5, kZeros, true);
  watch.restart();
  CHECK(run(watch, 4, 4 + SignalWatch::kSuspectS - kStep, kZeros, true) == Signal::kUnknown);
  CHECK(watch.check(4 + SignalWatch::kSuspectS, kZeros, true) ==
        Signal::kSilenceWhilePlaying);
  // A suspicion or sound already reached stays.
  watch.restart();
  CHECK(watch.signal() == Signal::kSilenceWhilePlaying);
  watch.check(30, kSound, false);
  watch.restart();
  CHECK(watch.done());
}

namespace {
struct Ring {
  nmr::LocalFrameRing ring{nmr::kMaxWriteChunk * 4};
  std::vector<float> scratch = std::vector<float>(size_t{nmr::kMaxWriteChunk} * 2);
  uint64_t checked = 0;

  void write(uint32_t frames, float value = 0) {
    std::vector<float> data(size_t{frames} * 2, 0.0f);
    if (value != 0) data[size_t{frames} * 2 - 1] = value;  // only the last sample
    ring.view().write(data.data(), frames);
  }
  Samples scan() { return SignalWatch::scan(ring.view(), checked, scratch.data()); }
};
}  // namespace

TEST_CASE("signal watch: scanning the ring sees what arrived since the last look") {
  Ring ring;
  CHECK(ring.scan() == kNone);
  ring.write(1000);
  CHECK(ring.scan() == kZeros);
  CHECK(ring.checked == 1000);
  CHECK(ring.scan() == kNone);  // nothing new
  ring.write(500, 0.25f);
  CHECK(ring.scan() == kSound);
  CHECK(ring.scan() == kNone);  // already seen
  // Over the end of the ring (capacity 16384), in pieces larger than one read.
  for (int i = 0; i < 4; ++i) {
    ring.write(nmr::kMaxWriteChunk);
    CHECK(ring.scan() == kZeros);
  }
  ring.write(nmr::kMaxWriteChunk * 2 + 7, -1e-30f);
  CHECK(ring.scan() == kSound);
}

TEST_CASE("signal watch: after a long gap only frames that can still be intact count") {
  Ring ring;
  // Sound, then more than the ring can hold: the sound is gone and must not count.
  ring.write(10, 0.5f);
  for (int i = 0; i < 5; ++i) ring.write(nmr::kMaxWriteChunk);
  CHECK(ring.scan() == kZeros);
  // Sound at the very end of a long gap is still seen.
  for (int i = 0; i < 5; ++i) ring.write(nmr::kMaxWriteChunk);
  ring.write(3, 0.5f);
  CHECK(ring.scan() == kSound);
}

TEST_CASE("signal watch: only exact zeros are silence") {
  std::vector<float> frames(256 * 2, 0.0f);
  CHECK_FALSE(SignalWatch::hasNonZero(frames.data(), 256));
  CHECK_FALSE(SignalWatch::hasNonZero(nullptr, 0));
  frames[2 * 100 + 1] = -0.0f;  // negative zero is a zero
  CHECK_FALSE(SignalWatch::hasNonZero(frames.data(), 256));
  frames[2 * 200 + 1] = 1e-30f;  // far below hearing, but not what a denied grant sends
  CHECK(SignalWatch::hasNonZero(frames.data(), 256));
  CHECK_FALSE(SignalWatch::hasNonZero(frames.data(), 200));  // only the frames asked about
  frames[2 * 200 + 1] = 0;
  frames[0] = std::numeric_limits<float>::quiet_NaN();
  CHECK(SignalWatch::hasNonZero(frames.data(), 256));
}
