// Runtime shader compilation, once per process.
//
// The Xcode Metal toolchain (`xcrun metal`) is not a build dependency, so the Metal Shading
// Language source is embedded in the binary and compiled with newLibraryWithSource: the first
// time a device asks for it. The library is cached per device for the life of the process, so
// opening a second editor or window costs nothing.
#pragma once

#ifdef __OBJC__
#import <Metal/Metal.h>

namespace nmr {

// The embedded MSL source: shaderSource() (Sources/Render/shader_source.mm) followed by
// meterShaderSource() (meter_shaders.mm), compiled as one library.
const char* shaderSource() noexcept;
const char* meterShaderSource() noexcept;

// Thread-safe. Returns nil (and logs) if compilation failed.
id<MTLLibrary> sharedShaderLibrary(id<MTLDevice> device);

// Thread-safe. Builds a render pipeline once per (device, key) and caches it. `configure`
// fills in everything except the functions, which are looked up by name.
id<MTLRenderPipelineState> sharedRenderPipeline(
    id<MTLDevice> device, NSString* key, NSString* vertex_function, NSString* fragment_function,
    void (^configure)(MTLRenderPipelineDescriptor* descriptor));

}  // namespace nmr

#endif  // __OBJC__
