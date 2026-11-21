#import <nmr/hello_scene.h>

#import <QuartzCore/CAMetalLayer.h>
#include <nmr/shader_library.h>

#include <simd/simd.h>

namespace nmr {

namespace {

constexpr long kMaxFramesInFlight = 3;
constexpr uint32_t kPointCount = 4096;
constexpr float kPointSizePt = 3.0f;
// Periwinkle iris #8993FF.
constexpr simd_float3 kIris = {0x89 / 255.0f, 0x93 / 255.0f, 0xFF / 255.0f};

// Matches HelloUniforms in shader_source.mm (float3 is 16-byte aligned in MSL and simd).
struct HelloUniforms {
  float time;
  float scale_x;
  float scale_y;
  float point_size;
  uint32_t count;
  simd_float3 color;
};

}  // namespace

HelloScene::HelloScene(id<MTLDevice> device, MTLPixelFormat format,
                       std::array<float, 4> background)
    : queue_([device newCommandQueue]),
      in_flight_(dispatch_semaphore_create(kMaxFramesInFlight)),
      background_(background) {
  NSString* key = [NSString stringWithFormat:@"hello/%lu", static_cast<unsigned long>(format)];
  pipeline_ = sharedRenderPipeline(device, key, @"hello_vertex", @"hello_fragment",
                                   ^(MTLRenderPipelineDescriptor* d) {
                                     d.colorAttachments[0].pixelFormat = format;
                                     d.colorAttachments[0].blendingEnabled = YES;
                                     d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
                                     d.colorAttachments[0].destinationRGBBlendFactor =
                                         MTLBlendFactorOne;
                                     d.colorAttachments[0].sourceAlphaBlendFactor =
                                         MTLBlendFactorOne;
                                     d.colorAttachments[0].destinationAlphaBlendFactor =
                                         MTLBlendFactorOne;
                                   });
}

void HelloScene::drawFrame(id<CAMetalDrawable> drawable, const FrameTiming& timing) {
  time_ += timing.dt;
  if (pipeline_ == nil || drawable == nil) return;
  // Skip a frame rather than block the render thread.
  if (dispatch_semaphore_wait(in_flight_, DISPATCH_TIME_NOW) != 0) return;

  id<MTLCommandBuffer> commands = [queue_ commandBuffer];
  dispatch_semaphore_t in_flight = in_flight_;
  [commands addCompletedHandler:^(id<MTLCommandBuffer>) {
    dispatch_semaphore_signal(in_flight);
  }];

  id<MTLTexture> target = drawable.texture;
  MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = target;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor =
      MTLClearColorMake(background_[0], background_[1], background_[2], background_[3]);

  const float width = static_cast<float>(target.width);
  const float height = static_cast<float>(target.height);
  const float scale = static_cast<float>(drawable.layer.contentsScale);
  HelloUniforms uniforms{};
  uniforms.time = static_cast<float>(time_);
  uniforms.scale_x = width > height ? height / width : 1.0f;
  uniforms.scale_y = height > width ? width / height : 1.0f;
  uniforms.point_size = kPointSizePt * scale;
  uniforms.count = kPointCount;
  uniforms.color = kIris;

  id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
  [encoder setRenderPipelineState:pipeline_];
  [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:kPointCount];
  [encoder endEncoding];

  [commands presentDrawable:drawable];
  [commands commit];
}

}  // namespace nmr
