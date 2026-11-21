// nmr_tap_probe_run: capture the system output for a while and summarize what arrived.
#include "nmr_corec.h"

#include <nmr/frame_ring.h>
#include <nmr/system_tap.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <thread>
#include <vector>

namespace {

constexpr uint32_t kRingFrames = 1u << 16;  // about 1.4 s at 48 kHz
constexpr auto kPollInterval = std::chrono::milliseconds(20);

struct Stats {
  uint64_t frames = 0;
  uint64_t nonzero_frames = 0;
  uint64_t lapped_frames = 0;
  uint64_t nonfinite_samples = 0;
  uint64_t finite_samples = 0;
  double sum_squares = 0;
  float peak = 0;

  void add(const float* interleaved, uint64_t count) {
    for (uint64_t i = 0; i < count; ++i) {
      bool nonzero = false;
      for (int c = 0; c < 2; ++c) {
        const float s = interleaved[2 * i + c];
        if (!std::isfinite(s)) {
          ++nonfinite_samples;
          continue;
        }
        nonzero = nonzero || s != 0.0f;
        peak = std::max(peak, std::fabs(s));
        sum_squares += double{s} * double{s};
        ++finite_samples;
      }
      if (nonzero) ++nonzero_frames;
    }
    frames += count;
  }
};

// Reads everything published since `cursor`, keeping only frames that were intact.
void drain(const nmr::FrameRingView& ring, uint64_t& cursor, std::vector<float>& scratch,
           Stats& stats) {
  const uint64_t written = ring.framesWritten();
  const uint64_t window = ring.capacity() - nmr::kMaxWriteChunk;
  if (written - cursor > window) {  // fell behind: jump to the newest readable window
    stats.lapped_frames += written - window - cursor;
    cursor = written - window;
  }
  const auto count = static_cast<uint32_t>(written - cursor);
  if (count == 0) return;
  const uint64_t intact = ring.read(cursor, count, scratch.data());
  const uint64_t skip = std::min<uint64_t>(intact - cursor, count);
  stats.lapped_frames += skip;
  stats.add(scratch.data() + skip * 2, count - skip);
  cursor = written;
}

}  // namespace

bool nmr_tap_probe_run(double seconds, nmr_tap_probe_result* result) {
  if (result == nullptr) return false;
  *result = nmr_tap_probe_result{};
  result->failed_step = "";
  try {
    nmr::LocalFrameRing ring(kRingFrames);
    const nmr::FrameRingView view = ring.view();
    std::vector<float> scratch(size_t{view.capacity()} * 2);
    nmr::SystemTap tap(view);

    const auto started = std::chrono::steady_clock::now();
    const OSStatus status = tap.start();
    result->start_seconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    result->status = status;
    result->failed_step = tap.failedStep();
    if (status != noErr) return false;

    const nmr::TapFormat format = tap.format();
    result->sample_rate = format.sample_rate;
    result->channels = format.channels;
    result->interleaved = format.interleaved;

    Stats stats;
    uint64_t cursor = view.framesWritten();
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::duration<double>(std::max(seconds, 0.0));
    while (std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(kPollInterval);
      drain(view, cursor, scratch, stats);
    }
    result->io_cycles = tap.ioCycles();
    result->skipped_cycles = tap.skippedCycles();
    tap.stop();
    drain(view, cursor, scratch, stats);

    result->frames = stats.frames;
    result->nonzero_frames = stats.nonzero_frames;
    result->lapped_frames = stats.lapped_frames;
    result->nonfinite_samples = stats.nonfinite_samples;
    result->peak = stats.peak;
    result->rms = stats.finite_samples > 0
                      ? static_cast<float>(std::sqrt(stats.sum_squares /
                                                     static_cast<double>(stats.finite_samples)))
                      : 0.0f;
    return true;
  } catch (...) {  // allocation failure; never let an exception cross the C API
    result->status = -1;
    result->failed_step = "out of memory";
    return false;
  }
}
