// Embedded Metal Shading Language source, compiled at runtime (see shader_library.h).
// Keep to MSL 3.1 (macOS 14).
#import <nmr/shader_library.h>

namespace nmr {

// What every shader below needs; the meter's shaders follow (meter_shaders.mm).
const char* shaderSource() noexcept {
  return R"MSL(
#include <metal_stdlib>
using namespace metal;
)MSL";
}

}  // namespace nmr
