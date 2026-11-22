// The paced playhead (docs/PROMPT.md §7): which source frames each display frame draws.
//
// Sources deliver audio in blocks (32 to 2048 frames and more) while the display wants an even
// share every frame. The playhead trails the writer by an adaptive latency, 1.5 × the largest
// recent block within 3–50 ms, and advances by sample rate × dt; a gentle correction (time
// constant 0.5 s) absorbs drift between the two clocks. The writer is estimated as a steady
// clock, sample rate × time plus the highest offset seen (count − rate × time when a block
// arrives: a block seen late only says the writer is at least there), at most one block ahead
// of what has arrived; the offset
// settles slowly (0.1 % of the rate) so a slower writer clock is followed, and a source that
// stopped and resumed is picked up at once.
//
// Each frame draws [previous playhead, new playhead): no frame twice, never one that has not
// been written, never one the ring may have overwritten, and at most 100 ms at once (after a
// stalled render thread, the newest). After a gap of more than 250 ms between display frames
// (the loop was stopped) or a time that goes back as far (a new clock), or when the count goes
// back (a new source), it starts over and draws again after the next block. A frame whose time
// is not a number or goes back less draws nothing. Render thread only; no allocation.
#pragma once

#include <cstdint>

namespace nmr {

// Source frames [begin, end).
struct FrameSpan {
  uint64_t begin = 0;
  uint64_t end = 0;
  [[nodiscard]] uint64_t size() const noexcept { return end - begin; }
  bool operator==(const FrameSpan&) const = default;
};

class Playhead {
 public:
  static constexpr double kLatencyBlocks = 1.5;
  static constexpr double kMinLatencyS = 0.003;
  static constexpr double kMaxLatencyS = 0.050;
  static constexpr double kCorrectionS = 0.5;   // time constant of the drift correction
  static constexpr double kBlockMemoryS = 2.0;  // how long a large block keeps the latency up
  static constexpr double kMaxSpanS = 0.1;      // the most one frame draws
  static constexpr double kMaxGapS = 0.25;      // a longer pause between frames starts over
  static constexpr double kSettle = 0.001;      // writer estimate settling, × rate per second
  static constexpr double kStallS = 0.1;        // a longer frame is a stall: it sees no block
  static constexpr double kMinRate = 8000;      // sample rates are held to this range
  static constexpr double kMaxRate = 768000;

  Playhead() noexcept { prepare(48000, 65536); }

  // `readable`: how many of the newest frames the source keeps intact (older ones may be
  // overwritten; for a FrameRingView, capacity() − kMaxWriteChunk). Resets.
  void prepare(double sample_rate, uint64_t readable) noexcept;
  void reset() noexcept;

  // One display frame at `time` (seconds, e.g. the display link's target timestamp, increasing)
  // when the source has written `written` frames in all.
  FrameSpan advance(double time, uint64_t written) noexcept;

  // How far the playhead trails the writer (seconds); the minimum before the first block.
  [[nodiscard]] double latencySeconds() const noexcept;

 private:
  void startOver() noexcept;  // like reset(), but never draws before what was drawn
  void seed(double time, uint64_t written) noexcept;
  void observe(double time, double dt, uint64_t written) noexcept;
  [[nodiscard]] double latencyFrames() const noexcept;

  double sample_rate_ = 48000;
  uint64_t readable_ = 0;
  uint64_t max_span_ = 0;

  bool timed_ = false;     // last_time_ holds a frame
  bool observed_ = false;  // seen_ holds a count
  bool seeded_ = false;    // a block has arrived since: the playhead moves
  double last_time_ = 0;
  uint64_t seen_ = 0;         // the newest count seen
  double arrival_time_ = 0;   // the frame that saw it
  double largest_ = 0;        // the largest recent block (frames)
  double anchor_ = 0;         // writer ≈ sample rate × time + anchor_
  double position_ = 0;       // the playhead (frames)
  uint64_t drawn_ = 0;        // everything before this has been drawn or skipped
};

}  // namespace nmr
