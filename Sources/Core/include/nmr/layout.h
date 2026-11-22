// Where the meter draws its parts in a view (pixels, origin top-left).
//
// The scope is square, or 2:1 for the half modes, centered in what the meters leave. The meters
// sit under it, full width: the correlation history strip, the correlation bar, then the balance
// bar, each with an optional readout at its right. Sizes follow the view (3 % margins; bars 3.5 %
// of the smaller side, 4–10 pt), so a thumbnail and a large window look alike. A view too short
// for the scope to keep at least 60 % of its height drops the meters; one too narrow for a bar
// to keep half its row drops the readouts.
#pragma once

namespace nmr {

struct Rect {
  float x = 0;
  float y = 0;
  float width = 0;
  float height = 0;
  [[nodiscard]] bool empty() const noexcept { return !(width > 0 && height > 0); }
  bool operator==(const Rect&) const = default;
};

struct LayoutInput {
  float width = 0;   // the view, in pixels
  float height = 0;
  float scale = 1;   // pixels per point (the backing scale)
  bool half = false;  // a half mode: 2:1 scope
  bool correlation = true;
  bool balance = true;
  bool readouts = false;
};

struct Layout {
  Rect scope;
  Rect correlation_history;  // empty when the correlation meter is off or dropped
  Rect correlation;
  Rect correlation_readout;  // empty without readouts
  Rect balance;
  Rect balance_readout;
};

struct LayoutMetrics {
  static constexpr float kMargin = 0.03f;      // of the smaller side
  static constexpr float kBar = 0.035f;        // bar height, of the smaller side
  static constexpr float kMinBarPt = 4;
  static constexpr float kMaxBarPt = 10;
  static constexpr float kHistoryBars = 2;     // the history strip, in bar heights
  static constexpr float kGapBars = 0.75f;     // between meters, in bar heights
  static constexpr float kReadoutBars = 5;     // a readout's width, in bar heights
  static constexpr float kMinScopeShare = 0.6f;
};

[[nodiscard]] Layout layout(const LayoutInput& input) noexcept;

}  // namespace nmr
