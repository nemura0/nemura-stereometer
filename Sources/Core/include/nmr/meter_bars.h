// The meters as filled rectangles in the view (pixels, origin top-left, as nmr::layout).
//
// Correlation bar: a track, a center mark and a fill from the center toward the value, in the
// positive color above 0 and the negative color below. Balance bar: the same, filled toward the
// louder side (−1 left … +1 right) in the positive color. History strip: a track and one column
// per value, oldest at the left, rising from the strip's middle for positive values and falling
// for negative ones; columns meet on whole pixels (edges rounded), at most one per pixel, and
// the newest are kept. Values that are not
// numbers read as 0 and all are held to −1 … 1. Colors are premultiplied RGBA. Render thread;
// no allocation.
#pragma once

#include <array>
#include <cstdint>
#include <span>

#include <nmr/layout.h>

namespace nmr {

using Premultiplied = std::array<float, 4>;

struct MeterPalette {
  Premultiplied track{0.05f, 0.05f, 0.06f, 0.08f};
  Premultiplied center{0.25f, 0.25f, 0.28f, 0.35f};
  Premultiplied positive{0x89 / 255.0f, 0x93 / 255.0f, 1.0f, 1.0f};        // #8993FF
  Premultiplied negative{0xE0 / 255.0f, 0x3C / 255.0f, 0x60 / 255.0f, 1.0f};  // #E03C60
};

struct BarRect {
  Rect rect;
  Premultiplied color{};
};

struct MeterBars {
  static constexpr uint32_t kMaxHistory = 480;
  static constexpr uint32_t kMaxRects = 8 + kMaxHistory;
  static constexpr float kCenterShare = 0.15f;  // the center mark's width, of the bar height
  std::array<BarRect, kMaxRects> rects{};
  uint32_t count = 0;
};

[[nodiscard]] MeterBars meterBars(const Layout& layout, float correlation, float balance,
                                  std::span<const float> history,
                                  const MeterPalette& palette = {}) noexcept;

}  // namespace nmr
