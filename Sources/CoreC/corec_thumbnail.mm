// Mode thumbnails, for the app's mode picker.
#include "nmr_corec.h"

#import <Metal/Metal.h>
#include <nmr/scene_settings.h>
#include <nmr/thumbnail.h>

#include "corec_internal.h"

#include <memory>

#if !__has_feature(objc_arc)
#error "Sources/CoreC is compiled with ARC (-fobjc-arc) in every build"
#endif

struct nmr_thumbnailer {
  std::unique_ptr<nmr::ThumbnailRenderer> renderer;
};

nmr_thumbnailer* nmr_thumbnailer_create(void) {
  return nmr::corec::guarded<nmr_thumbnailer*>(nullptr, [] () -> nmr_thumbnailer* {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) return nullptr;
    auto renderer = std::make_unique<nmr::ThumbnailRenderer>(device);
    if (!renderer->ready()) return nullptr;
    return new nmr_thumbnailer{std::move(renderer)};
  });
}

void nmr_thumbnailer_destroy(nmr_thumbnailer* thumbnailer) { delete thumbnailer; }

bool nmr_thumbnailer_render(nmr_thumbnailer* thumbnailer, const nmr_settings* settings,
                            const uint8_t* rgba, uint32_t width, uint32_t height, float scale,
                            uint8_t* bgra) {
  if (thumbnailer == nullptr || settings == nullptr || rgba == nullptr || bgra == nullptr) {
    return false;
  }
  return nmr::corec::guarded(false, [&] {
    nmr::colormap::Table table{};
    for (size_t i = 0; i < table.size(); ++i) {
      table[i] = {rgba[4 * i], rgba[4 * i + 1], rgba[4 * i + 2], rgba[4 * i + 3]};
    }
    const nmr::MeterSettings scene =
        nmr::meterSettings(settings->value, nmr::SceneHost::kApp, table);
    return thumbnailer->renderer->render(scene, width, height, scale, bgra);
  });
}
