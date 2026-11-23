#import <nmr/meter_renderer.h>

#include <nmr/readouts.h>
#include <nmr/shader_library.h>

#include <os/log.h>
#include <simd/simd.h>

#include <algorithm>
#include <cmath>

namespace nmr {

namespace {

// Mirrors of the MSL structs in meter_shaders.mm.
struct ScopeUniforms {
  simd_float4 solid_color;
  simd_float4 scope;  // in the light texture's pixels
  simd_float2 target_size;
  float full_scale;
  float size_px;
  float intensity;
  float map_low;
  float map_high;
  uint32_t density;
  uint32_t count;
  uint32_t shape;
  uint32_t solid;
  float soft_edge_px;
};
static_assert(sizeof(ScopeUniforms) == 80);

struct CompositeUniforms {
  simd_float4 scope_rect;
  simd_float4 light_rect;
  simd_float2 target_size;
  float full_scale;
  float tone_gain;
  float whiten;
  float guide_px;
  float glow;          // 0 … 1: the halo's amount
  float glow_divisor;  // light pixels per bloom texel
  simd_float4 glow_color;
  float glow_gain;
  float glow_ceiling;
  float edge_fade_px;
  float pad;
};
static_assert(sizeof(CompositeUniforms) == 96);

struct GpuSegment {
  simd_float2 a;
  simd_float2 b;
  simd_float4 color;
};
static_assert(sizeof(GpuSegment) == 32);

struct GpuRect {
  simd_float4 rect;
  simd_float4 color;
};
static_assert(sizeof(GpuRect) == 32);

struct GpuGlyph {
  simd_float4 rect;   // in target pixels
  simd_float4 color;  // premultiplied
  simd_float2 atlas;  // the cell's top left in the atlas
  simd_float2 pad;
};
static_assert(sizeof(GpuGlyph) == 48);

constexpr uint32_t kMaxGlyphs = 2 * ReadoutText::kMaxChars;

// One slot of per-frame data: the points (the previous frame's last first), the guides, the
// meter rects, the readouts' glyphs. Buffer offsets are 256-byte aligned, as macOS asks of
// buffers on any GPU.
constexpr size_t kOffsetAlignment = 256;
constexpr size_t aligned(size_t bytes) {
  return (bytes + kOffsetAlignment - 1) / kOffsetAlignment * kOffsetAlignment;
}
constexpr size_t kPointsBytes = (MeterRenderer::kMaxPoints + 1) * sizeof(simd_float4);
constexpr size_t kSegmentsOffset = aligned(kPointsBytes);
constexpr size_t kRectsOffset =
    aligned(kSegmentsOffset + Guides::kMaxSegments * sizeof(GpuSegment));
constexpr size_t kGlyphsOffset =
    aligned(kRectsOffset + MeterBars::kMaxRects * sizeof(GpuRect));
constexpr size_t kSlotBytes = kGlyphsOffset + kMaxGlyphs * sizeof(GpuGlyph);
constexpr uint32_t kAllSlots = (1u << MeterRenderer::kFramesInFlight) - 1;

constexpr MTLPixelFormat kLightFormat = MTLPixelFormatRGBA16Float;

simd_float4 simdOf(const Premultiplied& c) { return simd_make_float4(c[0], c[1], c[2], c[3]); }

const Premultiplied& guideColor(GuideKind kind, const MeterLook& look) {
  switch (kind) {
    case GuideKind::kStrong: return look.guide_strong;
    case GuideKind::kRing: return look.ring;
    case GuideKind::kWeak: break;
  }
  return look.guide_weak;
}

using Configure = void (^)(MTLRenderPipelineDescriptor*);

Configure blended(MTLPixelFormat format, MTLBlendFactor source, MTLBlendFactor destination,
                  MTLBlendOperation operation = MTLBlendOperationAdd) {
  return ^(MTLRenderPipelineDescriptor* d) {
    MTLRenderPipelineColorAttachmentDescriptor* color = d.colorAttachments[0];
    color.pixelFormat = format;
    color.blendingEnabled = YES;
    color.rgbBlendOperation = operation;
    color.alphaBlendOperation = operation;
    color.sourceRGBBlendFactor = source;
    color.sourceAlphaBlendFactor = source;
    color.destinationRGBBlendFactor = destination;
    color.destinationAlphaBlendFactor = destination;
  };
}

Configure opaque(MTLPixelFormat format) {
  return ^(MTLRenderPipelineDescriptor* d) { d.colorAttachments[0].pixelFormat = format; };
}

id<MTLTexture> lightTexture(id<MTLDevice> device, uint32_t width, uint32_t height) {
  MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:kLightFormat
                                                                               width:width
                                                                              height:height
                                                                           mipmapped:NO];
  d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  d.storageMode = MTLStorageModePrivate;
  return [device newTextureWithDescriptor:d];
}

}  // namespace

MeterRenderer::MeterRenderer(id<MTLDevice> device, MTLPixelFormat target_format)
    : device_(device),
      target_format_(target_format),
      free_slots_(std::make_shared<std::atomic<uint32_t>>(kAllSlots)) {
  if (device == nil) return;
  NSString* target = [NSString stringWithFormat:@"%lu", static_cast<unsigned long>(target_format)];
  const auto pipeline = [&](NSString* name, NSString* vertex, NSString* fragment,
                            Configure configure) {
    return sharedRenderPipeline(device, [@"meter/" stringByAppendingString:name], vertex,
                                fragment, configure);
  };
  constexpr MTLBlendFactor kOne = MTLBlendFactorOne;
  decay_ = pipeline(@"decay", @"fullscreen_vertex", @"decay_fragment",
                    blended(kLightFormat, MTLBlendFactorZero, MTLBlendFactorBlendColor));
  dots_ = pipeline(@"dots", @"dot_vertex", @"dot_fragment", blended(kLightFormat, kOne, kOne));
  trace_ = pipeline(@"trace", @"trace_vertex", @"segment_fragment",
                    blended(kLightFormat, kOne, kOne));
  const MTLBlendFactor over = MTLBlendFactorOneMinusSourceAlpha;
  image_ = pipeline([@"image/" stringByAppendingString:target], @"image_vertex",
                    @"image_fragment", blended(target_format, kOne, over));
  // Max, not over: where guide segments overlap (their joints) they are not drawn twice.
  guides_ = pipeline([@"guides/" stringByAppendingString:target], @"guide_vertex",
                     @"segment_fragment",
                     blended(target_format, kOne, kOne, MTLBlendOperationMax));
  rects_ = pipeline([@"rects/" stringByAppendingString:target], @"rect_vertex", @"rect_fragment",
                    blended(target_format, kOne, over));
  glyphs_ = pipeline([@"glyphs/" stringByAppendingString:target], @"glyph_vertex",
                     @"glyph_fragment", blended(target_format, kOne, over));
  glow_down_ = pipeline(@"glow_down", @"fullscreen_vertex", @"glow_down_fragment",
                        opaque(kLightFormat));
  glow_blur_ = pipeline(@"glow_blur", @"fullscreen_vertex", @"glow_blur_fragment",
                        opaque(kLightFormat));
  bool buffers = true;
  for (auto& buffer : buffers_) {
    buffer = [device newBufferWithLength:kSlotBytes options:MTLResourceStorageModeShared];
    buffers = buffers && buffer != nil;
  }
  ready_ = buffers && decay_ != nil && dots_ != nil && trace_ != nil && image_ != nil &&
           guides_ != nil && rects_ != nil && glow_down_ != nil && glow_blur_ != nil &&
           glyphs_ != nil;
  if (!ready_) os_log_error(OS_LOG_DEFAULT, "nmr: the meter renderer could not be set up");
  const colormap::Builtin* iris = colormap::findBuiltin(colormap::kDefaultKey);
  if (iris != nullptr) colormap_ = colormap::table(iris->stops);
}

void MeterRenderer::setColormap(const colormap::Table& table) noexcept { colormap_ = table; }

bool MeterRenderer::ensureScope(uint32_t width, uint32_t height) {
  // The scope's place in the light: where the target clips the bleed it can move inside a
  // texture of the same size, and the trail would shift with it.
  const Rect offset{scope_rect_.x - light_rect_.x, scope_rect_.y - light_rect_.y, 0, 0};
  const bool moved = offset.x != scope_offset_.x || offset.y != scope_offset_.y;
  scope_offset_ = offset;
  if (scope_ != nil && scope_.width == width && scope_.height == height) {
    scope_clear_ = scope_clear_ || moved;
    return true;
  }
  scope_ = lightTexture(device_, width, height);
  scope_clear_ = true;
  return scope_ != nil;
}

bool MeterRenderer::ensureGlow(uint32_t divisor) {
  const NSUInteger width = (scope_.width + divisor - 1) / divisor;
  const NSUInteger height = (scope_.height + divisor - 1) / divisor;
  if (glow_ != nil && glow_spare_ != nil && glow_divisor_ == divisor && glow_.width == width &&
      glow_.height == height) {
    return true;
  }
  glow_ = lightTexture(device_, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
  glow_spare_ = lightTexture(device_, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
  glow_divisor_ = divisor;
  return glow_ != nil && glow_spare_ != nil;
}

// The bloom: the light averaged over glow_divisor_ × glow_divisor_ pixel blocks, then a
// Gaussian blur across and down.
void MeterRenderer::encodeGlow(id<MTLCommandBuffer> commands) {
  const auto pass = [&](id<MTLTexture> into, id<MTLRenderPipelineState> state, id<MTLTexture> from,
                        const void* bytes, NSUInteger length) {
    MTLRenderPassDescriptor* d = [MTLRenderPassDescriptor renderPassDescriptor];
    d.colorAttachments[0].texture = into;
    d.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    d.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:d];
    [encoder setRenderPipelineState:state];
    [encoder setFragmentTexture:from atIndex:0];
    [encoder setFragmentBytes:bytes length:length atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
  };
  const uint32_t divisor = glow_divisor_;
  const simd_float2 across = simd_make_float2(1, 0);
  const simd_float2 down = simd_make_float2(0, 1);
  pass(glow_, glow_down_, scope_, &divisor, sizeof(divisor));
  pass(glow_spare_, glow_blur_, glow_, &across, sizeof(across));
  pass(glow_, glow_blur_, glow_spare_, &down, sizeof(down));
}

bool MeterRenderer::encode(id<MTLCommandBuffer> commands, id<MTLTexture> target,
                           const MeterFrame& frame, float scale) {
  pending_clear_ = pending_clear_ || frame.clear;
  if (!ready_ || commands == nil || target == nil || target.pixelFormat != target_format_) {
    return false;
  }
  // Take a free slot; the frame's completion hands it back.
  uint32_t free = free_slots_->load(std::memory_order_acquire);
  uint32_t index = 0;
  for (;;) {
    if (free == 0) return false;  // kFramesInFlight frames are still on the GPU: skip this one
    index = static_cast<uint32_t>(__builtin_ctz(free));
    if (free_slots_->compare_exchange_weak(free, free & ~(1u << index),
                                           std::memory_order_acq_rel)) {
      break;
    }
  }
  std::shared_ptr<std::atomic<uint32_t>> slots = free_slots_;
  [commands addCompletedHandler:^(id<MTLCommandBuffer>) {
    slots->fetch_or(1u << index, std::memory_order_release);
  }];
  id<MTLBuffer> slot = buffers_[index];

  // The scope in whole pixels, so the light texture maps 1:1 onto the target.
  const Rect& s = frame.layout.scope;
  const float x = std::round(s.x);
  const float y = std::round(s.y);
  scope_rect_ = {x, y, std::round(s.x + s.width) - x, std::round(s.y + s.height) - y};
  const float px = std::isfinite(scale) && scale > 0 ? scale : 1;
  placeLight(target, px, frame.style.size_px);
  float glow = std::isfinite(frame.glow) ? std::clamp(frame.glow, 0.0f, 1.0f) : 0.0f;
  if (scope_rect_.width >= 1 && scope_rect_.height >= 1 && light_rect_.width >= 1 &&
      light_rect_.height >= 1 &&
      ensureScope(static_cast<uint32_t>(light_rect_.width),
                  static_cast<uint32_t>(light_rect_.height))) {
    encodeScope(commands, slot, frame, px);
    // The bloom's texel stays kGlowTexelPt points wide, so it spreads as far at any scale.
    const auto divisor = static_cast<uint32_t>(
        std::clamp(std::round(px * kGlowTexelPt), 1.0f, float{kMaxGlowDivisor}));
    if (glow > 0 && ensureGlow(divisor)) {
      encodeGlow(commands);
    } else {
      glow = 0;
    }
  } else {
    glow = 0;
  }
  encodeComposite(commands, target, slot, frame, px, glow);
  return true;
}

// The light texture's place: the scope, and room for the glow and the dots past its edges,
// within the target.
void MeterRenderer::placeLight(id<MTLTexture> target, float scale, float size_px) {
  const float size = std::isfinite(size_px) ? std::clamp(size_px, 0.0f, ScopeExposure::kMaxSizePx)
                                            : 0.0f;
  // In steps of kBleedStepPx, so dragging the point size does not make a new texture (and a new
  // trail) at every step.
  const float bleed = std::ceil((kLightBleedPt * scale + size) / kBleedStepPx) * kBleedStepPx;
  const float x0 = std::max(scope_rect_.x - bleed, 0.0f);
  const float y0 = std::max(scope_rect_.y - bleed, 0.0f);
  const float x1 = std::min(scope_rect_.x + scope_rect_.width + bleed,
                            static_cast<float>(target.width));
  const float y1 = std::min(scope_rect_.y + scope_rect_.height + bleed,
                            static_cast<float>(target.height));
  light_rect_ = {x0, y0, std::max(x1 - x0, 0.0f), std::max(y1 - y0, 0.0f)};
}

void MeterRenderer::encodeScope(id<MTLCommandBuffer> commands, id<MTLBuffer> slot,
                                const MeterFrame& frame, float scale) {
  const bool clear = pending_clear_ || scope_clear_;
  scope_clear_ = false;
  if (clear) has_previous_ = false;  // a new trail joins nothing to the last one
  // Points: the previous frame's last sample, then the newest kMaxPoints of this frame's (not
  // joined across the ones left out).
  const size_t available = std::min(frame.points.size(), size_t{kMaxPoints});
  const size_t skipped = frame.points.size() - available;
  if (skipped > 0) has_previous_ = false;
  pending_clear_ = false;
  auto* points = static_cast<simd_float4*>(slot.contents);
  for (size_t i = 0; i < available; ++i) {
    const dsp::Point& p = frame.points[skipped + i];
    const size_t c = skipped + i;
    const float t = c < frame.colors.size() ? frame.colors[c] : 0.0f;
    points[i + 1] = simd_make_float4(p.x, p.y, t, 0);
  }
  if (available > 0) {
    points[0] = has_previous_ ? simd_make_float4(previous_.x, previous_.y, previous_color_, 0)
                              : points[1];
    previous_ = {points[available].x, points[available].y};
    previous_color_ = points[available].z;
    has_previous_ = true;
  }

  MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = scope_;
  pass.colorAttachments[0].loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
  const float decay = std::clamp(frame.style.decay, 0.0f, 1.0f);
  if (!clear && decay < 1) {
    [encoder setRenderPipelineState:decay_];
    [encoder setBlendColorRed:decay green:decay blue:decay alpha:decay];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  }
  if (available > 0 && frame.style.intensity > 0) {
    ScopeUniforms u{};
    const std::array<float, 3>& solid = frame.look.solid_color;
    u.solid_color = simd_make_float4(solid[0], solid[1], solid[2], 1);
    u.scope = simd_make_float4(scope_rect_.x - light_rect_.x, scope_rect_.y - light_rect_.y,
                               scope_rect_.width, scope_rect_.height);
    u.target_size = simd_make_float2(light_rect_.width, light_rect_.height);
    u.full_scale = kFullScale;
    u.size_px = frame.style.size_px;
    u.intensity = frame.style.intensity;
    u.map_low = frame.look.map_low;
    u.map_high = frame.look.map_high;
    u.density = std::clamp(frame.style.density, 1u, 8u);
    u.count = static_cast<uint32_t>(available);
    u.shape = static_cast<uint32_t>(frame.shape);
    u.solid = frame.look.solid ? 1 : 0;
    u.soft_edge_px = kSoftEdgePt * scale;
    const bool lines = frame.draw == DrawStyle::kLines;
    [encoder setRenderPipelineState:lines ? trace_ : dots_];
    [encoder setVertexBuffer:slot offset:0 atIndex:0];
    [encoder setVertexBytes:&u length:sizeof(u) atIndex:1];
    [encoder setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [encoder setVertexBytes:colormap_.data() length:sizeof(colormap_) atIndex:2];
    const NSUInteger instances = lines ? u.count : u.count * u.density;
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4
              instanceCount:instances];
  }
  [encoder endEncoding];
}

void MeterRenderer::encodeComposite(id<MTLCommandBuffer> commands, id<MTLTexture> target,
                                    id<MTLBuffer> slot, const MeterFrame& frame, float scale,
                                    float glow) {
  const Premultiplied& bg = frame.look.background;
  MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = target;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(bg[0], bg[1], bg[2], bg[3]);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];

  CompositeUniforms u{};
  u.scope_rect = simd_make_float4(scope_rect_.x, scope_rect_.y, scope_rect_.width,
                                  scope_rect_.height);
  u.light_rect = simd_make_float4(light_rect_.x, light_rect_.y, light_rect_.width,
                                  light_rect_.height);
  u.target_size = simd_make_float2(target.width, target.height);
  u.full_scale = kFullScale;
  u.tone_gain = kToneGain;
  u.whiten = std::isfinite(frame.look.whiten) ? std::clamp(frame.look.whiten, 0.0f, kMaxWhiten)
                                              : kWhiten;
  u.guide_px = kGuidePt * scale;
  u.glow = glow;
  u.glow_divisor = static_cast<float>(glow_divisor_);
  u.glow_gain = kGlowGain;
  u.glow_ceiling = kGlowCeiling;
  u.edge_fade_px = kEdgeFadePt * scale;
  const auto& gc = frame.look.glow_color;
  const auto channel = [](float v) { return std::isfinite(v) ? std::clamp(v, 0.0f, 1.0f) : 1; };
  u.glow_color = simd_make_float4(channel(gc[0]), channel(gc[1]), channel(gc[2]), 0);
  [encoder setVertexBytes:&u length:sizeof(u) atIndex:1];
  [encoder setFragmentBytes:&u length:sizeof(u) atIndex:1];
  const bool has_scope = scope_rect_.width >= 1 && scope_rect_.height >= 1 &&
                         light_rect_.width >= 1 && light_rect_.height >= 1 && scope_ != nil;

  uint32_t segments = 0;
  if (frame.guides != nullptr && has_scope) {
    auto* out = reinterpret_cast<GpuSegment*>(static_cast<uint8_t*>(slot.contents) +
                                              kSegmentsOffset);
    segments = std::min(frame.guides->count, Guides::kMaxSegments);
    for (uint32_t i = 0; i < segments; ++i) {
      const GuideSegment& g = frame.guides->segments[i];
      out[i] = {simd_make_float2(g.a.x, g.a.y), simd_make_float2(g.b.x, g.b.y),
                simdOf(guideColor(g.kind, frame.look))};
    }
  }
  if (segments > 0) {
    [encoder setRenderPipelineState:guides_];
    [encoder setVertexBuffer:slot offset:kSegmentsOffset atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4
              instanceCount:segments];
  }
  if (has_scope) {
    [encoder setRenderPipelineState:image_];
    [encoder setFragmentTexture:scope_ atIndex:0];
    [encoder setFragmentTexture:u.glow > 0 ? glow_ : scope_ atIndex:1];  // unread without glow
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  }

  const MeterBars bars = meterBars(frame.layout, frame.correlation, frame.balance,
                                   frame.correlation_history, frame.look.meters);
  if (bars.count > 0) {
    auto* out = reinterpret_cast<GpuRect*>(static_cast<uint8_t*>(slot.contents) + kRectsOffset);
    for (uint32_t i = 0; i < bars.count; ++i) {
      const Rect& r = bars.rects[i].rect;
      out[i] = {simd_make_float4(r.x, r.y, r.width, r.height), simdOf(bars.rects[i].color)};
    }
    [encoder setRenderPipelineState:rects_];
    [encoder setVertexBuffer:slot offset:kRectsOffset atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4
              instanceCount:bars.count];
  }
  encodeReadouts(encoder, slot, frame);
  [encoder endEncoding];
}

// The digit height for a readout place: kReadoutCap of its height, in whole pixels, less where
// the widest texts would not fit its width (as wide per pixel of digit as the last atlas).
float MeterRenderer::readoutCap(const Rect& readout) const noexcept {
  float cap = std::min(std::round(kReadoutCap * readout.height), GlyphAtlas::kMaxCapPx);
  if (atlas_width_per_cap_ > 0) {
    cap = std::min(cap, std::floor(readout.width / atlas_width_per_cap_));
  }
  return cap;
}

bool MeterRenderer::ensureAtlas(const Rect& readout) {
  // Glyph widths do not scale exactly with the size, so a build that comes out too wide is
  // tried again, a pixel smaller (rarely more than once).
  float below = GlyphAtlas::kMaxCapPx + 1;  // each retry is at least a pixel smaller
  for (int attempt = 0; attempt < kAtlasAttempts; ++attempt) {
    const float cap = std::min(readoutCap(readout), below - 1);
    below = cap;
    if (!(cap >= kMinReadoutCapPx) || cap == failed_cap_) {
      atlas_.clear();
      return false;
    }
    if (!atlas_.ready() || atlas_.capPx() != cap) {
      if (!atlas_.build(device_, cap)) {
        failed_cap_ = cap;  // not tried again on every frame
        return false;
      }
      failed_cap_ = 0;
    }
    const float widest = std::max(atlas_.width(balanceText(1).view()),
                                  atlas_.width(correlationText(-1).view()));
    atlas_width_per_cap_ = std::max(atlas_width_per_cap_, widest / cap);
    if (widest <= readout.width) return true;
  }
  atlas_.clear();
  return false;
}

// Each readout right-aligned in its place, its digits centered on the bar; pens on whole pixels.
void MeterRenderer::encodeReadouts(id<MTLRenderCommandEncoder> encoder, id<MTLBuffer> slot,
                                   const MeterFrame& frame) {
  const Layout& l = frame.layout;
  const Rect& sized = l.correlation_readout.empty() ? l.balance_readout : l.correlation_readout;
  if (sized.empty() || !ensureAtlas(sized)) return;
  auto* out = reinterpret_cast<GpuGlyph*>(static_cast<uint8_t*>(slot.contents) + kGlyphsOffset);
  uint32_t count = 0;
  const auto place = [&](const Rect& r, const ReadoutText& text, const Premultiplied& color) {
    if (r.empty()) return;
    float pen = std::round(r.x + r.width - atlas_.width(text.view()));
    const float baseline = std::round(r.y + 0.5f * (r.height + atlas_.capPx()));
    for (const char c : text.view()) {
      const GlyphAtlas::Glyph* g = atlas_.glyph(c);
      if (g == nullptr || count == kMaxGlyphs) continue;
      out[count++] = {simd_make_float4(std::round(pen) - atlas_.penX(),
                                       baseline - atlas_.baseline(), atlas_.cellWidth(),
                                       atlas_.cellHeight()),
                      simdOf(color), simd_make_float2(g->cell_x, 0), simd_make_float2(0, 0)};
      pen += g->advance;
    }
  };
  const MeterPalette& p = frame.look.meters;
  const ReadoutText correlation = correlationText(frame.correlation);
  const bool negative = correlation.length > 0 && correlation.chars[0] == '-';
  place(l.correlation_readout, correlation, negative ? p.negative : p.text);
  place(l.balance_readout, balanceText(frame.balance), p.text);
  if (count == 0) return;
  [encoder setRenderPipelineState:glyphs_];
  [encoder setVertexBuffer:slot offset:kGlyphsOffset atIndex:0];
  [encoder setFragmentTexture:atlas_.texture() atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
              vertexStart:0
              vertexCount:4
            instanceCount:count];
}

}  // namespace nmr
