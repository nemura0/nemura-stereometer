// The readouts' glyphs (nmr::kReadoutGlyphs), drawn once by CoreText into an R8 coverage
// texture at one size: each in its own cell, all cells the same size, with room around the ink
// so neighbours never bleed. Digits are tabular (one width), so a changing number keeps its
// place. Built on the render thread when the readouts' digit size changes. ObjC++ only.
#pragma once

#import <Metal/Metal.h>

#include <array>
#include <cstdint>
#include <string_view>

#include <nmr/readouts.h>

namespace nmr {

class GlyphAtlas {
 public:
  struct Glyph {
    uint32_t cell_x = 0;  // the cell's left edge in the texture (cells span its height)
    float advance = 0;    // how far the pen moves, in pixels
  };

  static constexpr float kMaxCapPx = 256;  // far above any readout

  // Draws the glyphs with digits `cap_px` pixels tall. False, leaving the atlas empty, when
  // CoreText or Metal fail (logged) or the size is not within 0 … kMaxCapPx.
  bool build(id<MTLDevice> device, float cap_px);
  void clear() noexcept;

  [[nodiscard]] bool ready() const noexcept { return texture_ != nil; }
  [[nodiscard]] id<MTLTexture> texture() const noexcept { return texture_; }
  [[nodiscard]] float capPx() const noexcept { return cap_px_; }
  [[nodiscard]] uint32_t cellWidth() const noexcept { return cell_width_; }
  [[nodiscard]] uint32_t cellHeight() const noexcept { return cell_height_; }
  // Where the pen sits in a cell: `pen_x` from its left edge, the baseline `baseline` from its
  // top.
  [[nodiscard]] uint32_t penX() const noexcept { return pen_x_; }
  [[nodiscard]] uint32_t baseline() const noexcept { return baseline_; }
  // Null for a character outside kReadoutGlyphs.
  [[nodiscard]] const Glyph* glyph(char c) const noexcept;
  // The pen's travel over `text` (characters without a glyph add nothing).
  [[nodiscard]] float width(std::string_view text) const noexcept;

 private:
  id<MTLTexture> texture_;
  float cap_px_ = 0;
  uint32_t cell_width_ = 0;
  uint32_t cell_height_ = 0;
  uint32_t pen_x_ = 0;
  uint32_t baseline_ = 0;
  std::array<Glyph, kReadoutGlyphs.size()> glyphs_{};
};

}  // namespace nmr
