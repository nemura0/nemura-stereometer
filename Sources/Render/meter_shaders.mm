// The meter renderer's MSL (see meter_renderer.h), appended to shaderSource() at compile time:
// it relies on that source's `#include <metal_stdlib>` and `using namespace metal`. The uniform
// structs mirror the ones in meter_renderer.mm.
#import <nmr/shader_library.h>

namespace nmr {

const char* meterShaderSource() noexcept {
  return R"MSL(
// ---------------------------------------------------------------------------------------------
// Meter renderer.

struct ScopeUniforms {
  float4 solid_color;
  float2 target_size;
  float full_scale;
  float size_px;
  float intensity;
  float map_low;
  float map_high;
  uint density;
  uint count;
  uint shape;
  uint solid;
  uint pad;
};

struct CompositeUniforms {
  float4 scope_rect;  // x, y, width, height in target pixels
  float2 target_size;
  float full_scale;
  float tone_gain;
  float whiten;
  float guide_px;
  float glow;
  float glow_divisor;  // scope pixels per bloom texel
};

struct GuideSegment {
  float2 a;
  float2 b;
  float4 color;  // premultiplied
};

struct MeterRect {
  float4 rect;
  float4 color;  // premultiplied
};

struct DotVertex {
  float4 position [[position]];
  float2 center [[flat]];
  float radius [[flat]];
  float4 color [[flat]];
};

struct SegmentVertex {
  float4 position [[position]];
  float2 a [[flat]];
  float2 b [[flat]];
  float half_width [[flat]];
  float4 color [[flat]];
};

struct RectVertex {
  float4 position [[position]];
  float4 rect [[flat]];
  float4 color [[flat]];
};

struct ImageVertex {
  float4 position [[position]];
};

// A point of the scope (±1 at full scale, Y up) in the pixels of a rect `size` wide (Y down).
static float2 scopePixel(float2 p, float2 size, float full_scale) {
  return float2(0.5 + 0.5 * full_scale * p.x, 0.5 - 0.5 * full_scale * p.y) * size;
}

static float4 pixelToClip(float2 px, float2 size) {
  return float4(px.x / size.x * 2.0 - 1.0, 1.0 - px.y / size.y * 2.0, 0.0, 1.0);
}

// Light that is NaN or infinite counts as dark. Tested on the bits: fast math may fold
// isfinite() to true.
static float3 finiteLight(float3 c) {
  const bool finite = all((as_type<uint3>(c) & 0x7f800000u) != 0x7f800000u);
  return finite ? max(c, 0.0) : 0.0;
}

static float2 quadCorner(uint vid) {  // triangle strip: (-1,-1) (1,-1) (-1,1) (1,1)
  return float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
}

static float3 mapColor(float t, constant ScopeUniforms& u, constant uchar4* map) {
  if (u.solid != 0) return u.solid_color.rgb;
  const float x = clamp(mix(u.map_low, u.map_high, clamp(t, 0.0, 1.0)), 0.0, 1.0) * 255.0;
  const uint i = min(uint(x), 254u);
  return mix(float4(map[i]).rgb, float4(map[i + 1]).rgb, x - float(i)) / 255.0;
}

// A quad around the segment a→b (pixels), `half_width` plus a pixel of antialiasing.
static SegmentVertex segmentQuad(uint vid, float2 a, float2 b, float half_width, float4 color,
                                 float2 size) {
  const float2 delta = b - a;
  const float length = metal::length(delta);
  const float2 along = length > 1e-4 ? delta / length : float2(1.0, 0.0);
  const float2 across = float2(-along.y, along.x);
  const float e = half_width + 1.0;
  const float2 corner = quadCorner(vid);
  const float2 px = a + along * (corner.x > 0 ? length + e : -e) + across * corner.y * e;
  SegmentVertex out;
  out.position = pixelToClip(px, size);
  out.a = a;
  out.b = b;
  out.half_width = half_width;
  out.color = color;
  return out;
}

vertex ImageVertex fullscreen_vertex(uint vid [[vertex_id]]) {
  const float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
  ImageVertex out;
  out.position = float4(p, 0.0, 1.0);
  return out;
}

// Blended with the blend color as the destination factor: light × decay.
fragment float4 decay_fragment(ImageVertex in [[stage_in]]) { return float4(0.0); }

// Instance i: the (i % density + 1)-th of `density` points between samples s − 1 and s, with
// s = 1 + i / density (point 0 is the previous frame's last sample).
vertex DotVertex dot_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            device const float4* points [[buffer(0)]],
                            constant ScopeUniforms& u [[buffer(1)]],
                            constant uchar4* map [[buffer(2)]]) {
  const uint s = 1 + iid / u.density;
  const float f = float(iid % u.density + 1) / float(u.density);
  const float4 a = points[s - 1];
  const float4 b = points[s];
  DotVertex out;
  out.center = scopePixel(mix(a.xy, b.xy, f), u.target_size, u.full_scale);
  out.radius = max(u.size_px * 0.5, 0.5);
  // Soft dots fade past their radius (to 0.4 % at 1.5 r): the quad reaches that far.
  const float extent = (u.shape == 0 ? 1.5 * out.radius : out.radius) + 1.0;
  out.position = pixelToClip(out.center + quadCorner(vid) * extent, u.target_size);
  out.color = float4(mapColor(mix(a.z, b.z, f), u, map) * u.intensity, u.intensity);
  return out;
}

fragment float4 dot_fragment(DotVertex in [[stage_in]], constant ScopeUniforms& u [[buffer(1)]]) {
  const float2 d = in.position.xy - in.center;
  float coverage;
  if (u.shape == 0) {  // soft
    coverage = exp(-2.5 * dot(d, d) / (in.radius * in.radius));
  } else if (u.shape == 1) {  // circle
    coverage = saturate(in.radius + 0.5 - length(d));
  } else {  // square
    coverage = saturate(in.radius + 0.5 - max(abs(d.x), abs(d.y)));
  }
  return in.color * coverage;
}

// Instance i: the segment from sample i to sample i + 1.
vertex SegmentVertex trace_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                  device const float4* points [[buffer(0)]],
                                  constant ScopeUniforms& u [[buffer(1)]],
                                  constant uchar4* map [[buffer(2)]]) {
  const float4 a = points[iid];
  const float4 b = points[iid + 1];
  const float3 rgb = mapColor(0.5 * (a.z + b.z), u, map) * u.intensity;
  return segmentQuad(vid, scopePixel(a.xy, u.target_size, u.full_scale),
                     scopePixel(b.xy, u.target_size, u.full_scale), max(u.size_px * 0.5, 0.5),
                     float4(rgb, u.intensity), u.target_size);
}

vertex SegmentVertex guide_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                  device const GuideSegment* segments [[buffer(0)]],
                                  constant CompositeUniforms& u [[buffer(1)]]) {
  const GuideSegment s = segments[iid];
  const float2 origin = u.scope_rect.xy;
  const float2 size = u.scope_rect.zw;
  return segmentQuad(vid, origin + scopePixel(s.a, size, u.full_scale),
                     origin + scopePixel(s.b, size, u.full_scale), 0.5 * u.guide_px, s.color,
                     u.target_size);
}

fragment float4 segment_fragment(SegmentVertex in [[stage_in]]) {
  const float2 p = in.position.xy;
  const float2 ab = in.b - in.a;
  const float length2 = dot(ab, ab);
  const float t = length2 > 0.0 ? saturate(dot(p - in.a, ab) / length2) : 0.0;
  const float distance = length(in.a + t * ab - p);
  return in.color * saturate(in.half_width + 0.5 - distance);
}

vertex ImageVertex image_vertex(uint vid [[vertex_id]],
                                constant CompositeUniforms& u [[buffer(1)]]) {
  const float2 corner = 0.5 * (quadCorner(vid) + 1.0);
  ImageVertex out;
  out.position = pixelToClip(u.scope_rect.xy + corner * u.scope_rect.zw, u.target_size);
  return out;
}

// Light to color: 1 − exp(−light × gain) per channel, and the hottest light turning white.
// Premultiplied, with alpha the brightest channel, so over a transparent background only the
// light shows.
fragment float4 image_fragment(ImageVertex in [[stage_in]],
                               constant CompositeUniforms& u [[buffer(1)]],
                               texture2d<float, access::read> light [[texture(0)]],
                               texture2d<float> glow [[texture(1)]]) {
  const uint2 size = uint2(light.get_width(), light.get_height());
  const float2 local = max(in.position.xy - u.scope_rect.xy, 0.0);
  const uint2 coord = min(uint2(local), size - 1);
  float3 c = finiteLight(light.read(coord).rgb);
  if (u.glow > 0.0) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    // The bloom's texels cover glow_divisor pixels each, up to a little past the scope.
    const float2 covered = float2(glow.get_width(), glow.get_height()) * u.glow_divisor;
    c += u.glow * max(glow.sample(linear, local / covered).rgb, 0.0);
  }
  const float3 m = 1.0 - exp(-c * u.tone_gain);
  const float white = 1.0 - exp(-(c.r + c.g + c.b) * u.tone_gain * u.whiten);
  const float3 rgb = m + (1.0 - m) * white;
  return float4(rgb, max(rgb.r, max(rgb.g, rgb.b)));
}

// The bloom, at kGlowTexelPt points per texel: each texel averages its divisor × divisor
// pixels (those inside the scope; a NaN or infinite one counts as dark, so a bad pixel cannot
// spread), then a 9-tap Gaussian (σ ≈ 2 texels, as 5 linear taps) runs across and down.
fragment float4 glow_down_fragment(ImageVertex in [[stage_in]],
                                   constant uint& divisor [[buffer(0)]],
                                   texture2d<float, access::read> light [[texture(0)]]) {
  const uint2 size = uint2(light.get_width(), light.get_height());
  const uint2 base = uint2(in.position.xy) * divisor;
  const uint2 end = min(base + divisor, size);
  float3 sum = 0.0;
  for (uint y = base.y; y < end.y; ++y) {
    for (uint x = base.x; x < end.x; ++x) {
      sum += finiteLight(light.read(uint2(x, y)).rgb);
    }
  }
  const uint2 count = end - min(base, end);
  return float4(sum / max(float(count.x * count.y), 1.0), 0.0);
}

fragment float4 glow_blur_fragment(ImageVertex in [[stage_in]],
                                   constant float2& direction [[buffer(0)]],
                                   texture2d<float> source [[texture(0)]]) {
  constexpr sampler linear(filter::linear, address::clamp_to_edge);
  const float2 size = float2(source.get_width(), source.get_height());
  const float2 uv = in.position.xy / size;
  const float2 step = direction / size;
  float3 sum = 0.2270270270 * source.sample(linear, uv).rgb;
  sum += 0.3162162162 * (source.sample(linear, uv + 1.3846153846 * step).rgb +
                         source.sample(linear, uv - 1.3846153846 * step).rgb);
  sum += 0.0702702703 * (source.sample(linear, uv + 3.2307692308 * step).rgb +
                         source.sample(linear, uv - 3.2307692308 * step).rgb);
  return float4(sum, 0.0);
}

vertex RectVertex rect_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              device const MeterRect* rects [[buffer(0)]],
                              constant CompositeUniforms& u [[buffer(1)]]) {
  const MeterRect r = rects[iid];
  const float2 corner = 0.5 * (quadCorner(vid) + 1.0);
  const float2 px = r.rect.xy - 1.0 + corner * (r.rect.zw + 2.0);  // a pixel to antialias
  RectVertex out;
  out.position = pixelToClip(px, u.target_size);
  out.rect = r.rect;
  out.color = r.color;
  return out;
}

fragment float4 rect_fragment(RectVertex in [[stage_in]]) {
  // How much of this pixel the rect covers (a box filter).
  const float2 p = in.position.xy;
  const float2 cover = max(min(p + 0.5, in.rect.xy + in.rect.zw) - max(p - 0.5, in.rect.xy), 0.0);
  return in.color * cover.x * cover.y;
}
)MSL";
}

}  // namespace nmr
