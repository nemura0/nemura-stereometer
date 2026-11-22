#include <nmr/layout.h>

#include <algorithm>
#include <cmath>

namespace nmr {

namespace {

using M = LayoutMetrics;

// One meter row: the bar, and its readout at the right when asked for.
void row(float x0, float x1, float y, float bar, float gap, bool readouts, Rect& meter,
         Rect& readout) {
  const float readout_width = readouts ? M::kReadoutBars * bar : 0;
  const float bar_end = readouts ? x1 - readout_width - gap : x1;
  meter = {x0, y, bar_end - x0, bar};
  if (readouts) readout = {x1 - readout_width, y, readout_width, bar};
}

}  // namespace

Layout layout(const LayoutInput& input) noexcept {
  Layout out;
  const float width = input.width;
  const float height = input.height;
  if (!(std::isfinite(width) && std::isfinite(height) && width > 0 && height > 0)) return out;
  const float scale = std::isfinite(input.scale) && input.scale > 0 ? input.scale : 1;
  const float side = std::min(width, height);
  const float margin = M::kMargin * side;
  const float x0 = margin;
  const float x1 = width - margin;
  const float y0 = margin;
  const float y1 = height - margin;
  const float bar = std::clamp(M::kBar * side, M::kMinBarPt * scale, M::kMaxBarPt * scale);
  const float gap = M::kGapBars * bar;
  // Readouts only where a bar keeps at least half its row.
  const bool readouts = input.readouts && M::kReadoutBars * bar + gap <= 0.5f * (x1 - x0);

  // The meters, bottom up, each above a gap.
  float meters = 0;
  if (input.correlation) meters += gap + M::kHistoryBars * bar + gap + bar;
  if (input.balance) meters += gap + bar;
  const float room = y1 - y0;
  const bool fits = meters > 0 && room - meters >= M::kMinScopeShare * room;
  if (fits) {
    float y = y1;
    if (input.balance) {
      y -= bar;
      row(x0, x1, y, bar, gap, readouts, out.balance, out.balance_readout);
      y -= gap;
    }
    if (input.correlation) {
      y -= bar;
      row(x0, x1, y, bar, gap, readouts, out.correlation, out.correlation_readout);
      y -= gap + M::kHistoryBars * bar;
      out.correlation_history = {x0, y, out.correlation.width, M::kHistoryBars * bar};
    }
  }

  // The scope, centered in the rest.
  const float area_width = x1 - x0;
  const float area_height = room - (fits ? meters : 0);
  const float scope_width = input.half ? std::min(area_width, 2 * area_height)
                                       : std::min(area_width, area_height);
  const float scope_height = input.half ? scope_width / 2 : scope_width;
  out.scope = {x0 + (area_width - scope_width) / 2, y0 + (area_height - scope_height) / 2,
               scope_width, scope_height};
  return out;
}

}  // namespace nmr
