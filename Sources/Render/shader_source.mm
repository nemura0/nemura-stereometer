// Embedded Metal Shading Language source, compiled at runtime (see shader_library.h).
// Keep to MSL 3.1 (macOS 14).
#import <nmr/shader_library.h>

namespace nmr {

const char* shaderSource() noexcept {
  return R"MSL(
#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------------------------
// Phase 0 hello scene: a glowing, slowly drifting Lissajous figure drawn as additive point
// sprites. It proves runtime compilation, the display link and the editor pipeline.

struct HelloUniforms {
  float time;
  float scale_x;
  float scale_y;
  float point_size;
  uint count;
  float3 color;
};

struct HelloPoint {
  float4 position [[position]];
  float point_size [[point_size]];
  float3 color;
};

vertex HelloPoint hello_vertex(uint vid [[vertex_id]], constant HelloUniforms& u [[buffer(0)]]) {
  float t = float(vid) / float(u.count);
  float a = 2.0 * M_PI_F * t;
  float left = 0.82 * sin(3.0 * a + 0.7 * u.time);
  float right = 0.82 * sin(2.0 * a + 0.3 * u.time);
  // Mid/side rotation: mono is vertical, left leans up-left.
  float2 p = float2((right - left) * 0.5, (left + right) * 0.5) * 1.15;
  HelloPoint out;
  out.position = float4(p.x * u.scale_x, p.y * u.scale_y, 0.0, 1.0);
  out.point_size = u.point_size;
  out.color = u.color;
  return out;
}

fragment float4 hello_fragment(HelloPoint in [[stage_in]], float2 coord [[point_coord]]) {
  float2 d = coord * 2.0 - 1.0;
  float r2 = dot(d, d);
  if (r2 > 1.0) {
    discard_fragment();
  }
  float glow = exp(-r2 * 4.0) * 0.22;
  return float4(in.color * glow, glow);
}
)MSL";
}

}  // namespace nmr
