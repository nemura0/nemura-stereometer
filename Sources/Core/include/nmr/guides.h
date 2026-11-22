// The scope's guides, as line segments in the scope's own coordinates (X and Y within −1 … 1,
// the same space as dsp::mapPoint).
//
// Subtle: the mono axis and the L and R axes (rays from the center to full scale, held to the
// view). Full adds the side axis and the view's unit circle (radius 1 of the view: M/S full
// scale; linear L/R the circle through full-scale left and right), and in the log modes the
// rings at −6, −12, −24 and −48 dB (of the sample's M/S radius, as dsp::amplitudeT) that fall
// inside the range and the view. The half modes keep the upper half (circles as half circles).
// Axes are "strong", circles "weak"; the renderer gives each its own look. With `ring`, the
// view's unit circle (0 dBFS in M/S) is drawn at any level as its own kind, the "ring" (in its
// place among Full's circles). Nothing is drawn twice: a circle that would lie on another is
// left out. The log range is held to dsp::kMinLogRangeDb … kMaxLogRangeDb (NaN: the default),
// as the analyzer holds it.
#pragma once

#include <array>
#include <cstdint>

#include <nmr/dsp.h>

namespace nmr {

enum class GuideLevel : uint8_t { kOff, kSubtle, kFull };  // the guides setting's order

enum class GuideKind : uint8_t { kWeak, kStrong, kRing };

struct GuideSegment {
  dsp::Point a;
  dsp::Point b;
  GuideKind kind = GuideKind::kWeak;
};

struct Guides {
  static constexpr uint32_t kCircleSegments = 96;
  static constexpr uint32_t kMaxSegments = 8 + 6 * kCircleSegments;
  std::array<GuideSegment, kMaxSegments> segments{};
  uint32_t count = 0;
};

// `params`: gain is ignored (guides mark full scale and dB of full scale).
[[nodiscard]] Guides guides(GuideLevel level, const dsp::MapParams& params,
                            bool ring = false) noexcept;

}  // namespace nmr
