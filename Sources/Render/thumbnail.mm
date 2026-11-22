#include "nmr/thumbnail.h"

#include <nmr/test_mix.h>

#include <cmath>
#include <cstring>
#include <vector>

namespace nmr {

ThumbnailRenderer::ThumbnailRenderer(id<MTLDevice> device)
    : device_(device), queue_(device != nil ? [device newCommandQueue] : nil) {}

bool ThumbnailRenderer::render(const MeterSettings& settings, uint32_t width, uint32_t height,
                               float scale, uint8_t* bgra) {
  if (!ready() || bgra == nullptr || width == 0 || height == 0 || width > kMaxSide ||
      height > kMaxSide || !(scale > 0) || !(scale <= kMaxScale)) {
    return false;
  }
  @autoreleasepool {
    MTLTextureDescriptor* d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget;
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device_ newTextureWithDescriptor:d];
    const NSUInteger row = NSUInteger{width} * 4;
    id<MTLBuffer> readback = [device_ newBufferWithLength:row * height
                                                  options:MTLResourceStorageModeShared];
    // A fresh ring, scene and mix each time: the same pixels for the same look. Do not keep the
    // scene between calls: setSource leaves its history, governor and idle detector as they were.
    // The ring outlives the scene, which reads it.
    const LocalFrameRing ring(1 << 15);
    MeterScene scene(device_, MTLPixelFormatBGRA8Unorm);
    if (target == nil || readback == nil || !scene.ready()) return false;

    const auto per_frame = static_cast<uint32_t>(kSampleRate / kFrameRate);
    scene.setSource(ring.view(), kSampleRate);
    scene.setSettings(settings);
    TestMix mix(kSampleRate);
    mix.skip(static_cast<uint64_t>(kStartS * kSampleRate));
    std::vector<float> block(size_t{per_frame} * 2);
    const auto frames = static_cast<int>(std::lround(kSettleS * kFrameRate));
    double time = 1;
    for (int i = 0; i < frames; ++i, time += 1 / kFrameRate) {
      mix.fill(block.data(), per_frame);
      ring.view().write(block.data(), per_frame);
      id<MTLCommandBuffer> commands = [queue_ commandBuffer];
      if (commands == nil) return false;
      const FrameTiming timing{.target_time = time, .present_time = time, .dt = 1 / kFrameRate};
      // A frame missed would leave the trail short of a clean run's: no thumbnail rather than
      // a different one.
      if (!scene.render(commands, target, timing, scale)) return false;
      if (i + 1 == frames) {
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        [blit copyFromTexture:target
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(width, height, 1)
                            toBuffer:readback
                   destinationOffset:0
              destinationBytesPerRow:row
            destinationBytesPerImage:row * height];
        [blit endEncoding];
      }
      [commands commit];
      [commands waitUntilCompleted];  // the next frame reuses the scene's buffers
      if (commands.status == MTLCommandBufferStatusError) return false;
    }
    std::memcpy(bgra, readback.contents, row * height);
  }
  return true;
}

}  // namespace nmr
