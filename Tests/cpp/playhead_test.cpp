#include <nmr/playhead.h>

#include <doctest/doctest.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <random>
#include <vector>

namespace {

using nmr::FrameSpan;
using nmr::Playhead;

struct Block {
  double time;       // when the reader can see it
  uint64_t written;  // the count once it is in
};

// `block` frames every block / rate seconds, each up to `jitter_s` late, for `seconds`.
std::vector<Block> steadySource(double rate, uint32_t block, double seconds, double jitter_s,
                                uint32_t seed) {
  std::mt19937 rng(seed);
  std::uniform_real_distribution<double> jitter(0, jitter_s);
  std::vector<Block> blocks;
  for (uint64_t k = 0;; ++k) {
    const double time = static_cast<double>(k + 1) * block / rate + jitter(rng);
    if (time > seconds) break;
    blocks.push_back({time, (k + 1) * block});
  }
  return blocks;
}

struct Frame {
  FrameSpan span;
  uint64_t written;  // the count this frame saw
};

// The display side: a frame targeted at `time` whose callback runs `late` seconds after it sees
// every block that arrived by then (in order: a block is seen after the ones before it).
class Display {
 public:
  Display(std::vector<Block> blocks, Playhead& playhead)
      : blocks_(std::move(blocks)), playhead_(playhead) {}

  Frame frame(double time, double late = 0) {
    while (next_ < blocks_.size() && blocks_[next_].time <= time + late) {
      written_ = blocks_[next_++].written;
    }
    return {playhead_.advance(time, written_), written_};
  }

 private:
  std::vector<Block> blocks_;
  Playhead& playhead_;
  size_t next_ = 0;
  uint64_t written_ = 0;
};

// What a run drew: per-frame counts after the warm-up, and every broken rule.
struct Pacing {
  std::vector<double> counts;
  uint64_t beyond_written = 0;  // frames drawn before they were written
  uint64_t skipped = 0;         // frames left out between two spans
  uint64_t repeated = 0;        // frames drawn twice

  [[nodiscard]] double mean() const {
    double sum = 0;
    for (double c : counts) sum += c;
    return counts.empty() ? 0 : sum / static_cast<double>(counts.size());
  }
  [[nodiscard]] double sd() const {
    const double m = mean();
    double sum = 0;
    for (double c : counts) sum += (c - m) * (c - m);
    return counts.empty() ? 0 : std::sqrt(sum / static_cast<double>(counts.size()));
  }
};

class Checker {
 public:
  void see(const Frame& frame, Pacing& pacing) {
    if (frame.span.end > frame.written) ++pacing.beyond_written;
    if (frame.span.end == 0) return;  // nothing drawn yet
    if (seen_) {
      if (frame.span.begin > previous_end_) pacing.skipped += frame.span.begin - previous_end_;
      if (frame.span.begin < previous_end_) pacing.repeated += previous_end_ - frame.span.begin;
    }
    seen_ = true;
    previous_end_ = frame.span.end;
  }

 private:
  bool seen_ = false;
  uint64_t previous_end_ = 0;
};

// A steady source and a display at `fps` whose callbacks run up to 0.2 ms late.
Pacing pace(double rate, uint32_t block, double fps, double seconds = 6, double warmup = 2) {
  Playhead playhead;
  playhead.prepare(rate, 65536);
  Display display(steadySource(rate, block, seconds + 1, 0.0005, 1), playhead);
  std::mt19937 rng(2);
  std::uniform_real_distribution<double> late(0, 0.0002);
  Pacing pacing;
  Checker checker;
  for (int f = 0; f < static_cast<int>(seconds * fps); ++f) {
    const double time = f / fps;
    const Frame frame = display.frame(time, late(rng));
    checker.see(frame, pacing);
    if (time >= warmup) pacing.counts.push_back(static_cast<double>(frame.span.size()));
  }
  return pacing;
}

double latencyAfter(double rate, uint32_t block, double fps, double seconds = 2) {
  Playhead playhead;
  playhead.prepare(rate, 65536);
  Display display(steadySource(rate, block, seconds + 1, 0.0005, 3), playhead);
  for (int f = 0; f < static_cast<int>(seconds * fps); ++f) display.frame(f / fps);
  return playhead.latencySeconds();
}

}  // namespace

TEST_CASE("playhead: draws nothing until it has seen a block arrive") {
  Playhead playhead;
  playhead.prepare(48000, 65536);
  constexpr double kFrame = 1.0 / 120;
  CHECK(playhead.advance(0 * kFrame, 0) == FrameSpan{});
  CHECK(playhead.advance(1 * kFrame, 512).size() == 0);  // the first count it sees
  CHECK(playhead.advance(2 * kFrame, 512).size() == 0);
  CHECK(playhead.advance(3 * kFrame, 1024).size() == 0);  // a block arrived: it starts here
  uint64_t drawn = 0;
  uint64_t written = 1024;
  for (int f = 4; f < 60; ++f) {
    if (f % 2 == 0) written += 512;
    const FrameSpan span = playhead.advance(f * kFrame, written);
    CHECK(span.end <= written);
    drawn += span.size();
  }
  CHECK(drawn > 0);
}

TEST_CASE("playhead: even motion for any block size, sample rate and frame rate") {
  for (double rate : {44100.0, 48000.0, 96000.0}) {
    for (uint32_t block : {32u, 256u, 480u, 800u, 1024u, 2048u}) {
      for (double fps : {60.0, 120.0}) {
        CAPTURE(rate);
        CAPTURE(block);
        CAPTURE(fps);
        const Pacing pacing = pace(rate, block, fps);
        CHECK(pacing.mean() == doctest::Approx(rate / fps).epsilon(0.005));
        CHECK(pacing.sd() <= 0.005 * pacing.mean());
        CHECK(pacing.beyond_written == 0);
        CHECK(pacing.skipped == 0);
        CHECK(pacing.repeated == 0);
      }
    }
  }
}

TEST_CASE("playhead: follows a writer clock that runs a little slow or fast") {
  constexpr double kRate = 48000;
  constexpr double kFps = 120;
  for (double ppm : {-800.0, 800.0}) {
    CAPTURE(ppm);
    const double actual = kRate * (1 + ppm * 1e-6);  // the device clock against the display's
    Playhead playhead;
    playhead.prepare(kRate, 65536);
    Display display(steadySource(actual, 256, 41, 0.0005, 9), playhead);
    Pacing pacing;
    Checker checker;
    uint64_t closest = UINT64_MAX;  // how near the writer it came
    for (int f = 0; f < 40 * kFps; ++f) {
      const Frame frame = display.frame(f / kFps);
      checker.see(frame, pacing);
      if (f < 10 * kFps) continue;
      pacing.counts.push_back(static_cast<double>(frame.span.size()));
      closest = std::min(closest, frame.written - frame.span.end);
    }
    // It keeps trailing: a writer estimate that ran ahead would creep up on the writer.
    CHECK(static_cast<double>(closest) >= 0.5 * playhead.latencySeconds() * kRate);
    CHECK(pacing.mean() == doctest::Approx(actual / kFps).epsilon(0.0002));
    CHECK(pacing.sd() <= 0.005 * pacing.mean());
    CHECK(pacing.beyond_written == 0);
    CHECK(pacing.skipped == 0);
    CHECK(pacing.repeated == 0);
  }
}

TEST_CASE("playhead: trails the writer by 1.5 blocks, within 3 to 50 ms") {
  // 1024-frame blocks at 48 kHz: 1.5 × 1024 / 48000 = 32 ms.
  CHECK(latencyAfter(48000, 1024, 120) == doctest::Approx(0.032).epsilon(0.01));
  // 2048-frame blocks would need 64 ms: held at 50 ms.
  CHECK(latencyAfter(48000, 2048, 120) == doctest::Approx(0.050));
  CHECK(latencyAfter(44100, 2048, 60) == doctest::Approx(0.050));
  // Small blocks arrive several per display frame: what one frame sees counts as the block.
  const double small = latencyAfter(48000, 32, 120);
  CHECK(small >= 1.5 * 384 / 48000.0);
  CHECK(small <= 1.5 * 448 / 48000.0);
  // A very fast display sees one or two small blocks at a time: held at 3 ms.
  CHECK(latencyAfter(48000, 32, 1000) == doctest::Approx(0.003));
}

TEST_CASE("playhead: the latency comes back down when the blocks get smaller") {
  constexpr double kRate = 48000;
  constexpr double kFps = 120;
  std::vector<Block> blocks = steadySource(kRate, 2048, 2, 0.0005, 10);
  const uint64_t switched = blocks.back().written;
  const double at = blocks.back().time;
  for (const Block& block : steadySource(kRate, 256, 8, 0.0005, 11)) {
    blocks.push_back({at + block.time, switched + block.written});
  }
  Playhead playhead;
  playhead.prepare(kRate, 65536);
  Display display(blocks, playhead);
  int f = 0;
  for (; f < 2 * kFps; ++f) display.frame(f / kFps);
  CHECK(playhead.latencySeconds() == doctest::Approx(0.050));
  // Once the large blocks are a few seconds old: 1.5 × what a frame sees (one or two blocks).
  for (; f < 9 * kFps; ++f) display.frame(f / kFps);
  CHECK(playhead.latencySeconds() >= 1.5 * 256 / kRate);
  CHECK(playhead.latencySeconds() <= 1.5 * 512 / kRate);
}

TEST_CASE("playhead: starts evenly") {
  for (uint32_t block : {256u, 2048u}) {
    for (double fps : {60.0, 120.0}) {
      CAPTURE(block);
      CAPTURE(fps);
      constexpr double kRate = 48000;
      Playhead playhead;
      playhead.prepare(kRate, 65536);
      Display display(steadySource(kRate, block, 2, 0.0005, 12), playhead);
      uint64_t most = 0;
      for (int f = 0; f < fps; ++f) most = std::max(most, display.frame(f / fps).span.size());
      CHECK(static_cast<double>(most) <= 1.5 * kRate / fps);
    }
  }
}

TEST_CASE("playhead: after a stalled frame it jumps ahead and draws at most 100 ms") {
  constexpr double kRate = 48000;
  constexpr double kFps = 120;
  Playhead playhead;
  playhead.prepare(kRate, 65536);
  Display display(steadySource(kRate, 256, 6, 0.0005, 4), playhead);
  Pacing pacing;
  Checker checker;
  int f = 0;
  for (; f < 2 * kFps; ++f) checker.see(display.frame(f / kFps), pacing);
  const double latency = playhead.latencySeconds();
  // The render thread stalls for 200 ms: the next frame catches up, keeping only the newest.
  const Frame catchUp = display.frame((f + 24) / kFps);
  CHECK(catchUp.span.size() > 0);
  CHECK(catchUp.span.size() <= static_cast<uint64_t>(Playhead::kMaxSpanS * kRate));
  CHECK(catchUp.span.end <= catchUp.written);
  CHECK(catchUp.written - catchUp.span.end <= static_cast<uint64_t>(0.05 * kRate));
  // What a long frame saw is no block: the latency stays.
  CHECK(playhead.latencySeconds() == doctest::Approx(latency));
  // Then motion is even again.
  for (f += 25; f < 5 * kFps; ++f) {
    const Frame frame = display.frame(f / kFps);
    checker.see(frame, pacing);
    if (f >= 3.5 * kFps) pacing.counts.push_back(static_cast<double>(frame.span.size()));
  }
  CHECK(pacing.mean() == doctest::Approx(kRate / kFps).epsilon(0.005));
  CHECK(pacing.sd() <= 0.005 * pacing.mean());
  CHECK(pacing.beyond_written == 0);
  CHECK(pacing.repeated == 0);
}

TEST_CASE("playhead: a long pause between frames starts over") {
  constexpr double kRate = 48000;
  constexpr double kFps = 120;
  Playhead playhead;
  playhead.prepare(kRate, 65536);
  Display display(steadySource(kRate, 512, 6, 0.0005, 5), playhead);
  int f = 0;
  for (; f < kFps; ++f) display.frame(f / kFps);
  // The loop was stopped for a second (idle, occluded): nothing old is drawn.
  f += static_cast<int>(kFps);
  CHECK(display.frame(f / kFps).span.size() == 0);
  uint64_t drawn = 0;
  for (++f; f < 2.5 * kFps; ++f) {
    const Frame frame = display.frame(f / kFps);
    CHECK(frame.span.end <= frame.written);
    drawn += frame.span.size();
  }
  CHECK(drawn > 0.4 * kRate);
}

TEST_CASE("playhead: a source that stops is never passed, and resumes evenly") {
  constexpr double kRate = 48000;
  constexpr double kFps = 120;
  std::vector<Block> blocks;
  for (const Block& block : steadySource(kRate, 512, 2, 0.0005, 6)) blocks.push_back(block);
  // Nothing for a second, then blocks again from where it stopped.
  const uint64_t stopped = blocks.back().written;
  for (const Block& block : steadySource(kRate, 512, 4, 0.0005, 7)) {
    blocks.push_back({3 + block.time, stopped + block.written});
  }
  Playhead playhead;
  playhead.prepare(kRate, 65536);
  Display display(blocks, playhead);
  Pacing pacing;
  Checker checker;
  uint64_t during_stop = 0;
  for (int f = 0; f < 7 * kFps; ++f) {
    const double time = f / kFps;
    const Frame frame = display.frame(time);
    checker.see(frame, pacing);
    if (time > 2.2 && time < 3) during_stop += frame.span.size();
    if (time >= 5) pacing.counts.push_back(static_cast<double>(frame.span.size()));
  }
  CHECK(during_stop == 0);
  CHECK(pacing.beyond_written == 0);
  CHECK(pacing.repeated == 0);
  CHECK(pacing.mean() == doctest::Approx(kRate / kFps).epsilon(0.005));
  CHECK(pacing.sd() <= 0.005 * pacing.mean());
}

TEST_CASE("playhead: a count that goes back (a new source) starts over") {
  constexpr double kFrame = 1.0 / 120;
  Playhead playhead;
  playhead.prepare(48000, 65536);
  uint64_t written = 1'000'000;
  int f = 0;
  for (; f < 120; ++f) playhead.advance(f * kFrame, written += 400);
  written = 512;
  CHECK(playhead.advance(f++ * kFrame, written).size() == 0);
  uint64_t drawn = 0;
  for (; f < 240; ++f) {
    written += 400;
    const FrameSpan span = playhead.advance(f * kFrame, written);
    CHECK(span.end <= written);
    CHECK(span.begin >= 512);
    drawn += span.size();
  }
  CHECK(drawn > 0);
}

TEST_CASE("playhead: never draws frames the ring may have overwritten") {
  constexpr double kRate = 48000;
  constexpr double kFps = 120;
  constexpr uint64_t kCapacity = 4096;
  Playhead playhead;
  playhead.prepare(kRate, kCapacity);
  Display display(steadySource(kRate, 2048, 4, 0.0005, 8), playhead);
  int f = 0;
  for (; f < 2 * kFps; ++f) {
    const Frame frame = display.frame(f / kFps);
    if (frame.written > kCapacity) CHECK(frame.span.begin >= frame.written - kCapacity);
  }
  // A 200 ms stall would catch up by 100 ms: more than the ring holds.
  const Frame catchUp = display.frame((f + 24) / kFps);
  CHECK(catchUp.span.size() > 0);
  CHECK(catchUp.span.begin >= catchUp.written - kCapacity);
}

TEST_CASE("playhead: prepare starts over") {
  constexpr double kFrame = 1.0 / 120;
  Playhead playhead;
  playhead.prepare(48000, 65536);
  uint64_t written = 0;
  int f = 0;
  for (; f < 120; ++f) playhead.advance(f * kFrame, written += 400);
  playhead.prepare(96000, 65536);
  CHECK(playhead.advance(f++ * kFrame, written += 800).size() == 0);
  CHECK(playhead.advance(f++ * kFrame, written += 800).size() == 0);
}

TEST_CASE("playhead: keeps its rules whatever the source and the display do") {
  for (uint32_t seed = 1; seed <= 20; ++seed) {
    CAPTURE(seed);
    std::mt19937 rng(seed);
    const double rate = std::uniform_int_distribution<int>(0, 1)(rng) ? 44100 : 96000;
    const uint64_t capacity = std::uniform_int_distribution<int>(0, 1)(rng) ? 8192 : 65536;
    // Blocks of random sizes, sometimes late, with pauses.
    std::vector<Block> blocks;
    double clock = 0;
    uint64_t written = 0;
    std::uniform_int_distribution<uint32_t> size(1, 4096);
    std::uniform_real_distribution<double> unit(0, 1);
    while (clock < 10) {
      const uint32_t n = size(rng);
      clock += n / rate;
      if (unit(rng) < 0.002) clock += unit(rng);  // the source pauses
      written += n;
      blocks.push_back({clock + 0.002 * unit(rng), written});
    }
    Playhead playhead;
    playhead.prepare(rate, capacity);
    Display display(blocks, playhead);
    Pacing pacing;
    Checker checker;
    double time = 0;
    while (time < 10) {
      time += 1.0 / 120 + (unit(rng) < 0.03 ? 0.3 * unit(rng) : 0);  // the display hiccups
      const Frame frame = display.frame(time, 0.001 * unit(rng));
      checker.see(frame, pacing);
      CHECK(frame.span.begin <= frame.span.end);
      CHECK(frame.span.size() <= static_cast<uint64_t>(Playhead::kMaxSpanS * rate));
      if (frame.written > capacity) CHECK(frame.span.begin >= frame.written - capacity);
    }
    CHECK(pacing.beyond_written == 0);
    CHECK(pacing.repeated == 0);
  }
}

TEST_CASE("playhead: ignores a frame whose time is not a number") {
  constexpr double kRate = 48000;
  constexpr double kFps = 120;
  Playhead playhead;
  playhead.prepare(kRate, 65536);
  Display display(steadySource(kRate, 512, 5, 0.0005, 13), playhead);
  Pacing pacing;
  Checker checker;
  for (int f = 0; f < 4 * kFps; ++f) {
    const double time = f == 2 || f == kFps ? std::nan("") : f / kFps;
    const Frame frame = display.frame(time);
    checker.see(frame, pacing);
    if (f == 2 || f == kFps) CHECK(frame.span.size() == 0);
    if (f >= 2 * kFps) pacing.counts.push_back(static_cast<double>(frame.span.size()));
  }
  CHECK(pacing.mean() == doctest::Approx(kRate / kFps).epsilon(0.005));
  CHECK(pacing.sd() <= 0.005 * pacing.mean());
  CHECK(pacing.beyond_written == 0);
  CHECK(pacing.repeated == 0);
}

TEST_CASE("playhead: a frame that goes back in time draws nothing, and no burst after") {
  constexpr double kRate = 48000;
  constexpr double kFps = 120;
  Playhead playhead;
  playhead.prepare(kRate, 65536);
  Display display(steadySource(kRate, 512, 4, 0.0005, 14), playhead);
  int f = 0;
  for (; f < 2 * kFps; ++f) display.frame(f / kFps);
  CHECK(display.frame((f - 12) / kFps).span.size() == 0);  // 100 ms back
  for (; f < 3 * kFps; ++f) CHECK(display.frame(f / kFps).span.size() <= 1.5 * kRate / kFps);
}

TEST_CASE("playhead: a clock that starts again from zero starts over") {
  constexpr double kRate = 48000;
  constexpr double kFrame = 1.0 / 120;
  Playhead playhead;
  playhead.prepare(kRate, 65536);
  uint64_t written = 0;
  for (int f = 0; f < 240; ++f) playhead.advance(1e4 + f * kFrame, written += 400);
  CHECK(playhead.advance(0, written += 400).size() == 0);
  uint64_t previous_end = 0;
  for (int f = 1; f < 2400; ++f) {
    const FrameSpan span = playhead.advance(f * kFrame, written += 400);
    CHECK(span.end <= written);
    if (previous_end != 0 && span.size() > 0) CHECK(span.begin == previous_end);
    if (span.size() > 0) previous_end = span.end;
  }
  CHECK(previous_end > 0);
  CHECK(playhead.latencySeconds() == doctest::Approx(1.5 * 400 / kRate));
}

TEST_CASE("playhead: holds a sample rate to 8 to 768 kHz and draws nothing from an empty ring") {
  constexpr double kFrame = 1.0 / 120;
  for (double rate : {0.0, -1.0, 1e-300, 1e30, std::nan(""), HUGE_VAL}) {
    CAPTURE(rate);
    Playhead playhead;
    playhead.prepare(rate, 65536);
    CHECK(playhead.latencySeconds() >= Playhead::kMinLatencyS);
    CHECK(playhead.latencySeconds() <= Playhead::kMaxLatencyS);
    uint64_t written = 0;
    uint64_t drawn = 0;
    for (int f = 0; f < 240; ++f) {
      const FrameSpan span = playhead.advance(f * kFrame, written += 400);
      CHECK(span.end <= written);
      CHECK(span.size() <= static_cast<uint64_t>(Playhead::kMaxSpanS * 768000));
      drawn += span.size();
    }
    CHECK(drawn > 0);
  }
  Playhead empty;
  empty.prepare(48000, 0);
  uint64_t written = 0;
  for (int f = 0; f < 240; ++f) CHECK(empty.advance(f * kFrame, written += 400).size() == 0);
}

TEST_CASE("playhead: reset starts over from the next count") {
  constexpr double kFrame = 1.0 / 120;
  Playhead playhead;
  playhead.prepare(48000, 65536);
  uint64_t written = 0;
  int f = 0;
  for (; f < 240; ++f) playhead.advance(f * kFrame, written += 400);
  playhead.reset();
  const uint64_t at_reset = written += 400;
  CHECK(playhead.advance(f++ * kFrame, at_reset).size() == 0);
  for (; f < 480; ++f) CHECK(playhead.advance(f * kFrame, written += 400).begin >= at_reset);
}
