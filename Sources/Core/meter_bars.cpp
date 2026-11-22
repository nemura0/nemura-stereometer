#include <nmr/meter_bars.h>

#include <algorithm>
#include <cmath>

namespace nmr {

namespace {

float held(float value) noexcept {
  return std::isnan(value) ? 0.0f : std::clamp(value, -1.0f, 1.0f);
}

class Builder {
 public:
  explicit Builder(MeterBars& bars) : bars_(bars) {}

  void add(const Rect& rect, const Premultiplied& color) {
    if (rect.empty() || bars_.count == MeterBars::kMaxRects) return;
    bars_.rects[bars_.count++] = {rect, color};
  }

  // A track, the fill from the center toward `value` (−1 … 1), then the center mark on top.
  void bar(const Rect& bar, float value, const Premultiplied& positive,
           const Premultiplied& negative, const MeterPalette& palette) {
    if (bar.empty()) return;
    add(bar, palette.track);
    const float middle = bar.x + bar.width / 2;
    const float reach = held(value) * bar.width / 2;
    add({std::min(middle, middle + reach), bar.y, std::abs(reach), bar.height},
        reach >= 0 ? positive : negative);
    const float mark = bar.height * MeterBars::kCenterShare;
    add({middle - mark / 2, bar.y, mark, bar.height}, palette.center);
  }

  // The newest values that fit, one column each, oldest at the left.
  void history(const Rect& strip, std::span<const float> values, const MeterPalette& palette) {
    if (strip.empty()) return;
    add(strip, palette.track);
    const auto columns = static_cast<size_t>(std::min<double>(
        {static_cast<double>(values.size()), std::floor(strip.width), MeterBars::kMaxHistory}));
    if (columns == 0) return;
    const float width = strip.width / static_cast<float>(columns);
    const float middle = strip.y + strip.height / 2;
    const std::span<const float> shown = values.last(columns);
    // Columns meet on whole pixels: a shared edge inside a pixel would leave a seam.
    float left = std::round(strip.x);
    for (size_t i = 0; i < columns; ++i) {
      const float right = std::round(strip.x + static_cast<float>(i + 1) * width);
      const float height = held(shown[i]) * strip.height / 2;
      add({left, std::min(middle, middle - height), right - left, std::abs(height)},
          height >= 0 ? palette.positive : palette.negative);
      left = right;
    }
  }

 private:
  MeterBars& bars_;
};

}  // namespace

MeterBars meterBars(const Layout& layout, float correlation, float balance,
                    std::span<const float> history, const MeterPalette& palette) noexcept {
  MeterBars bars;
  Builder build(bars);
  build.history(layout.correlation_history, history, palette);
  build.bar(layout.correlation, correlation, palette.positive, palette.negative, palette);
  build.bar(layout.balance, balance, palette.positive, palette.positive, palette);
  return bars;
}

float phaseWarning(float correlation) noexcept {
  if (!std::isfinite(correlation)) return 0;
  const float t = std::clamp(correlation / kPhaseWarningFull, 0.0f, 1.0f);
  return t * t * (3 - 2 * t);  // smoothstep
}

}  // namespace nmr
