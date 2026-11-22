#include "nmr/file_player.h"

#include <nmr/monotonic_clock.h>

#include <pthread.h>
#include <sys/qos.h>

#include <algorithm>
#include <chrono>
#include <utility>

namespace nmr {

FilePlayer::FilePlayer(wav::Audio audio) : audio_(std::move(audio)) {}

FilePlayer::~FilePlayer() { stop(); }

bool FilePlayer::start() noexcept {
  if (audio_.frames() == 0 || !(audio_.sample_rate > 0)) return false;
  if (running_.exchange(true)) return true;
  try {
    thread_ = std::thread([this] { run(); });
  } catch (...) {  // std::system_error: no thread to be had
    running_.store(false, std::memory_order_release);
    return false;
  }
  return true;
}

void FilePlayer::stop() {
  running_.store(false, std::memory_order_release);
  if (thread_.joinable()) thread_.join();
}

void FilePlayer::run() {
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  const MonotonicClock clock;
  const uint64_t start_ns = clock.nowNs();
  const uint64_t frames = audio_.frames();
  uint64_t played = 0;  // since this start
  while (running_.load(std::memory_order_acquire)) {
    const auto due = static_cast<uint64_t>(static_cast<double>(clock.nowNs() - start_ns) * 1e-9 *
                                           audio_.sample_rate);
    played = catchUp(played, due);
    while (played + kBlockFrames <= due) {
      uint32_t left = kBlockFrames;
      while (left > 0) {  // a block may cross the end of the file
        const auto n = static_cast<uint32_t>(std::min<uint64_t>(left, frames - position_));
        ring_.view().write(audio_.stereo.data() + position_ * 2, n);
        position_ = (position_ + n) % frames;
        left -= n;
      }
      played += kBlockFrames;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(kTickMs));
  }
}

}  // namespace nmr
