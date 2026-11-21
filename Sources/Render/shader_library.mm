#import <nmr/shader_library.h>

#import <Foundation/Foundation.h>
#include <os/log.h>

#include <mutex>

namespace nmr {

namespace {

std::mutex& cacheMutex() {
  static std::mutex mutex;
  return mutex;
}

// Keyed by MTLDevice.registryID; values are id<MTLLibrary> / id<MTLRenderPipelineState>.
NSMutableDictionary<NSNumber*, id<MTLLibrary>>* libraries() {
  static NSMutableDictionary* dictionary = [NSMutableDictionary new];
  return dictionary;
}

NSMutableDictionary<NSString*, id<MTLRenderPipelineState>>* pipelines() {
  static NSMutableDictionary* dictionary = [NSMutableDictionary new];
  return dictionary;
}

id<MTLLibrary> compileLocked(id<MTLDevice> device) {
  NSNumber* key = @(device.registryID);
  if (id<MTLLibrary> cached = libraries()[key]) return cached;

  MTLCompileOptions* options = [MTLCompileOptions new];
  // Pin the language version so newer OS compilers cannot change behavior (macOS 14 baseline).
  options.languageVersion = MTLLanguageVersion3_1;
  NSError* error = nil;
  NSString* source = [NSString stringWithUTF8String:shaderSource()];
  id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
  if (library == nil) {
    os_log_error(OS_LOG_DEFAULT, "nmr: shader compilation failed: %{public}@",
                 error.localizedDescription);
    return nil;
  }
  libraries()[key] = library;
  return library;
}

}  // namespace

id<MTLLibrary> sharedShaderLibrary(id<MTLDevice> device) {
  std::lock_guard<std::mutex> lock(cacheMutex());
  return compileLocked(device);
}

id<MTLRenderPipelineState> sharedRenderPipeline(
    id<MTLDevice> device, NSString* key, NSString* vertex_function, NSString* fragment_function,
    void (^configure)(MTLRenderPipelineDescriptor* descriptor)) {
  std::lock_guard<std::mutex> lock(cacheMutex());
  NSString* cache_key = [NSString stringWithFormat:@"%llu/%@", device.registryID, key];
  if (id<MTLRenderPipelineState> cached = pipelines()[cache_key]) return cached;

  id<MTLLibrary> library = compileLocked(device);
  if (library == nil) return nil;
  MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction = [library newFunctionWithName:vertex_function];
  descriptor.fragmentFunction = [library newFunctionWithName:fragment_function];
  if (descriptor.vertexFunction == nil || descriptor.fragmentFunction == nil) {
    os_log_error(OS_LOG_DEFAULT, "nmr: missing shader function for pipeline %{public}@", key);
    return nil;
  }
  configure(descriptor);
  NSError* error = nil;
  id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:descriptor
                                                                            error:&error];
  if (state == nil) {
    os_log_error(OS_LOG_DEFAULT, "nmr: pipeline %{public}@ failed: %{public}@", key,
                 error.localizedDescription);
    return nil;
  }
  pipelines()[cache_key] = state;
  return state;
}

}  // namespace nmr
