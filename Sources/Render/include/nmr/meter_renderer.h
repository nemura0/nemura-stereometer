// The meter's Metal renderer: the scope's trail, its guides and the meter bars.
//
// The scope accumulates light in an rgba16Float texture the size of the layout's scope rect.
// Each frame first fades it by the style's decay (a blend with a constant, no read-back), then
// adds the frame's new points: instanced quads (soft, circle or square dots, with `density`
// points interpolated per sample in the vertex shader) or antialiased segments joining
// consecutive samples, the first from the last point of the previous frame. Full scale (±1) is
// kFullScale of the scope's half size. The composite pass clears the target to the background,
// draws the guides, the tone-mapped scope (premultiplied, so a transparent background shows only
// the light) and the meter bars.
//
// Render thread only. Encoding never blocks: with kFramesInFlight frames still on the GPU it
// skips the frame. Per-frame data goes into one of kFramesInFlight preallocated shared buffers,
// each handed back when the GPU has finished the frame that used it: every command buffer
// passed to encode() that returned true must be committed.
#pragma once

#ifdef __OBJC__
#import <Metal/Metal.h>

#include <nmr/colormap.h>
#include <nmr/dsp.h>
#include <nmr/glyph_atlas.h>
#include <nmr/guides.h>
#include <nmr/layout.h>
#include <nmr/meter_bars.h>
#include <nmr/scope_style.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <span>

namespace nmr {

enum class PointShape : uint8_t { kSoft, kCircle, kSquare };  // the point_shape setting's order

struct MeterLook {
  Premultiplied background{0, 0, 0, 0};
  bool solid = false;                       // one color instead of the colormap
  std::array<float, 3> solid_color{0x89 / 255.0f, 0x93 / 255.0f, 1.0f};
  float map_low = 0;                        // the slice of the colormap that t = 0 … 1 spans
  float map_high = 1;
  Premultiplied guide_strong{0.16f, 0.16f, 0.18f, 0.22f};
  Premultiplied guide_weak{0.07f, 0.07f, 0.08f, 0.10f};
  MeterPalette meters{};
};

struct MeterFrame {
  // The frame's new samples, mapped (dsp::mapPoint, finite) and their color coordinates
  // (0 … 1; missing ones read as 0). More than MeterRenderer::kMaxPoints keeps the newest, not
  // joined to the previous frame.
  std::span<const dsp::Point> points;
  std::span<const float> colors;
  ScopeStyle style{};
  DrawStyle draw = DrawStyle::kDots;
  PointShape shape = PointShape::kSoft;
  bool clear = false;  // forget the trail (and the previous point); kept until a frame draws
  float glow = 0;      // 0 … 1: light spread around the trace (a low-resolution bloom)
  Layout layout{};     // in the target's pixels
  const Guides* guides = nullptr;
  float correlation = 0;
  float balance = 0;
  std::span<const float> correlation_history;  // oldest first
  MeterLook look{};
};

class MeterRenderer {
 public:
  static constexpr uint32_t kMaxPoints = 76800;  // 100 ms at 768 kHz (the playhead's cap)
  static constexpr long kFramesInFlight = 3;
  static constexpr float kFullScale = 0.94f;
  static constexpr float kToneGain = 1.6f;  // composite: 1 − exp(−light × gain)
  static constexpr float kWhiten = 0.12f;   // and hot light turning white
  static constexpr float kGuidePt = 1;      // guide thickness
  static constexpr uint32_t kGlowTexelPt = 4;  // the bloom's texel, in points (whole pixels)
  static constexpr uint32_t kMaxGlowDivisor = 16;  // its texel at most, in pixels
  static constexpr float kGlowGain = 2.5f;     // light added at glow 1 (of the blurred light)
  static constexpr float kReadoutCap = 0.9f;   // readout digits' height, of the bar's
  static constexpr float kMinReadoutCapPx = 3;  // smaller readouts are not drawn
  static constexpr int kAtlasAttempts = 3;      // builds per frame to fit the widest readout

  MeterRenderer(id<MTLDevice> device, MTLPixelFormat target_format);
  MeterRenderer(const MeterRenderer&) = delete;
  MeterRenderer& operator=(const MeterRenderer&) = delete;

  // False when the shaders or buffers could not be made (logged); encode() then does nothing.
  [[nodiscard]] bool ready() const noexcept { return ready_; }

  void setColormap(const colormap::Table& table) noexcept;

  // Encodes one frame into `commands`, drawing into all of `target` (`scale`: pixels per point).
  // Returns false, encoding nothing, when kFramesInFlight frames are still on the GPU, the
  // target is not of the format given at construction, or the renderer is not ready.
  bool encode(id<MTLCommandBuffer> commands, id<MTLTexture> target, const MeterFrame& frame,
              float scale = 1);

 private:
  // False when a texture could not be made; the frame then goes without it.
  bool ensureScope(uint32_t width, uint32_t height);
  bool ensureGlow(uint32_t divisor);
  void encodeGlow(id<MTLCommandBuffer> commands);
  void encodeScope(id<MTLCommandBuffer> commands, id<MTLBuffer> slot, const MeterFrame& frame);
  void encodeComposite(id<MTLCommandBuffer> commands, id<MTLTexture> target, id<MTLBuffer> slot,
                       const MeterFrame& frame, float scale, float glow);
  void encodeReadouts(id<MTLRenderCommandEncoder> encoder, id<MTLBuffer> slot,
                      const MeterFrame& frame);
  [[nodiscard]] float readoutCap(const Rect& readout) const noexcept;
  // The atlas for readouts in this place, rebuilt when their digit size changes; false if
  // there is none.
  bool ensureAtlas(const Rect& readout);

  id<MTLDevice> device_;
  MTLPixelFormat target_format_;
  bool ready_ = false;
  id<MTLRenderPipelineState> decay_;
  id<MTLRenderPipelineState> dots_;
  id<MTLRenderPipelineState> trace_;
  id<MTLRenderPipelineState> image_;
  id<MTLRenderPipelineState> guides_;
  id<MTLRenderPipelineState> rects_;
  id<MTLRenderPipelineState> glow_down_;
  id<MTLRenderPipelineState> glow_blur_;
  id<MTLRenderPipelineState> glyphs_;
  // Bit i set: buffers_[i] is free. Shared with the completion handlers, which may run after
  // the renderer is gone.
  std::shared_ptr<std::atomic<uint32_t>> free_slots_;
  std::array<id<MTLBuffer>, kFramesInFlight> buffers_;
  bool pending_clear_ = false;
  id<MTLTexture> scope_;  // the accumulated light
  // The light averaged over glow_divisor_² pixel blocks, blurred (with glow_spare_ for the
  // blur's first pass); made when glow is first on.
  id<MTLTexture> glow_;
  id<MTLTexture> glow_spare_;
  uint32_t glow_divisor_ = 0;
  GlyphAtlas atlas_;
  float atlas_width_per_cap_ = 0;  // the widest readout's width per pixel of digit height
  float failed_cap_ = 0;           // a digit size whose atlas could not be made
  Rect scope_rect_{};    // where it sits in the target, in whole pixels
  bool scope_clear_ = true;
  bool has_previous_ = false;
  dsp::Point previous_{};
  float previous_color_ = 0;
  colormap::Table colormap_{};
};

}  // namespace nmr

#endif  // __OBJC__
