// --feed: a file played in real time into a ring, looped.
#include <doctest/doctest.h>
#include <nmr/file_player.h>
#include <nmr/monotonic_clock.h>

#include <chrono>
#include <cstdint>
#include <thread>
#include <vector>

namespace {

nmr::wav::Audio ramp(uint32_t frames, double rate) {
  nmr::wav::Audio audio;
  audio.sample_rate = rate;
  for (uint32_t i = 0; i < frames; ++i) {
    audio.stereo.push_back(static_cast<float>(i) / frames);
    audio.stereo.push_back(-static_cast<float>(i) / frames);
  }
  return audio;
}

// Waits (up to 5 s) until the player has written `frames`.
bool waitFor(const nmr::FilePlayer& player, uint64_t frames) {
  for (int i = 0; i < 500 && player.view().framesWritten() < frames; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return player.view().framesWritten() >= frames;
}

}  // namespace

TEST_CASE("file player: plays the file in order and loops at its end") {
  const nmr::wav::Audio audio = ramp(480, 48000);  // 10 ms
  nmr::FilePlayer player(audio);
  CHECK(player.sampleRate() == 48000);
  REQUIRE(player.view().valid());
  CHECK(player.view().framesWritten() == 0);  // nothing before start
  player.start();
  REQUIRE(waitFor(player, 480 * 3));
  player.stop();
  std::vector<float> read(480 * 2 * 2);
  REQUIRE(player.view().read(480, 960, read.data()) == 480);  // the second and third laps
  for (uint32_t i = 0; i < 960; ++i) {
    CHECK(read[2 * i] == audio.stereo[2 * (i % 480)]);
    CHECK(read[2 * i + 1] == audio.stereo[2 * (i % 480) + 1]);
  }
}

TEST_CASE("file player: never runs ahead of real time, and stops when asked") {
  nmr::FilePlayer player(ramp(48000, 48000));
  const nmr::MonotonicClock clock;
  const uint64_t start = clock.nowNs();
  player.start();
  std::this_thread::sleep_for(std::chrono::milliseconds(120));
  const double elapsed = static_cast<double>(clock.nowNs() - start) * 1e-9;
  const uint64_t written = player.view().framesWritten();
  CHECK(written > 0);
  CHECK(static_cast<double>(written) <= elapsed * 48000 + nmr::FilePlayer::kBlockFrames);
  player.stop();
  const uint64_t stopped = player.view().framesWritten();
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  CHECK(player.view().framesWritten() == stopped);
  player.stop();  // twice is fine
}

TEST_CASE("file player: starting again goes on from where it stopped, in the same ring") {
  const nmr::wav::Audio audio = ramp(48000, 48000);
  nmr::FilePlayer player(audio);
  player.start();
  REQUIRE(waitFor(player, 2048));
  player.stop();
  const uint64_t stopped = player.view().framesWritten();
  player.start();
  REQUIRE(waitFor(player, stopped + 512));
  player.stop();
  std::vector<float> read(2);
  REQUIRE(player.view().read(stopped, 1, read.data()) == stopped);
  CHECK(read[0] == audio.stereo[2 * (stopped % 48000)]);
}

TEST_CASE("file player: after a stall it skips the missed audio instead of a burst") {
  using nmr::FilePlayer;
  CHECK(FilePlayer::catchUp(0, 1000) == 0);  // on time: everything due is played
  CHECK(FilePlayer::catchUp(4096, 4096 + FilePlayer::kRingFrames / 2) == 4096);
  const uint64_t due = 4096 + FilePlayer::kRingFrames;  // stopped longer than half the ring
  const uint64_t resumed = FilePlayer::catchUp(4096, due);
  CHECK(resumed <= due);
  CHECK(due - resumed < FilePlayer::kBlockFrames);
  CHECK(resumed % FilePlayer::kBlockFrames == 0);
}
