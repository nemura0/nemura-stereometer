// The meter view's settings and the system capture, for the app.
#include "nmr_corec.h"

#import <AppKit/AppKit.h>
#import <nmr/render_view.h>
#include <nmr/scene_settings.h>
#include <nmr/system_capture.h>

#include "corec_internal.h"

#include <memory>

#if !__has_feature(objc_arc)
#error "Sources/CoreC is compiled with ARC (-fobjc-arc) in every build"
#endif

static_assert(NMR_COLORMAP_TABLE_SIZE == nmr::colormap::kTableSize);
static_assert(NMR_SIGNAL_UNKNOWN == static_cast<int>(nmr::Signal::kUnknown));
static_assert(NMR_SIGNAL_SOUND == static_cast<int>(nmr::Signal::kSound));
static_assert(NMR_SIGNAL_SILENCE_WHILE_PLAYING ==
              static_cast<int>(nmr::Signal::kSilenceWhilePlaying));

struct nmr_capture {
  std::unique_ptr<nmr::SystemCapture> capture;
};

bool nmr_render_view_apply(void* view, const nmr_settings* settings, const uint8_t* rgba) {
  if (view == nullptr || settings == nullptr || rgba == nullptr) return false;
  return nmr::corec::guarded(false, [&] {
    nmr::colormap::Table table{};
    for (size_t i = 0; i < table.size(); ++i) {
      table[i] = {rgba[4 * i], rgba[4 * i + 1], rgba[4 * i + 2], rgba[4 * i + 3]};
    }
    NMR_OBJC(RenderView)* target = (__bridge NMR_OBJC(RenderView)*)view;
    [target setSettings:nmr::meterSettings(settings->value, nmr::SceneHost::kApp, table)];
    return true;
  });
}

bool nmr_render_view_is_rendering(void* view) {
  return view != nullptr && ((__bridge NMR_OBJC(RenderView)*)view).isRendering;
}

bool nmr_render_view_is_idle(void* view) {
  return view != nullptr && ((__bridge NMR_OBJC(RenderView)*)view).isIdle;
}

bool nmr_render_view_frame_stats(void* view, nmr_frame_stats* out) {
  if (view == nullptr || out == nullptr) return false;
  const nmr::FrameStats::Summary s = ((__bridge NMR_OBJC(RenderView)*)view).frameStats;
  *out = {s.frames,     s.presented,  s.dropped,     s.intervals,  s.period_ms,
          s.p1_ms,      s.p50_ms,     s.p99_ms,      s.max_ms,     s.worked,
          s.over_period, s.cpu_p99_ms, s.cpu_max_ms, s.gpu_p99_ms, s.gpu_max_ms};
  return true;
}

void nmr_render_view_reset_frame_stats(void* view) {
  if (view != nullptr) [(__bridge NMR_OBJC(RenderView)*)view resetFrameStats];
}

nmr_capture* nmr_capture_create(void* view, nmr_capture_status_fn callback, void* context,
                                bool sound_seen_before) {
  if (view == nullptr) return nullptr;
  NMR_OBJC(RenderView)* target = (__bridge NMR_OBJC(RenderView)*)view;
  nmr::SystemCapture::StatusHandler handler = ^(nmr::CaptureStatus status) {
    if (callback == nullptr) return;
    const nmr_capture_status out{status.status, status.failed_step, status.sample_rate,
                                 status.channels, status.rebuilds,
                                 static_cast<uint8_t>(status.signal)};
    callback(context, &out);
  };
  return nmr::corec::guarded<nmr_capture*>(nullptr, [&] {
    auto capture = std::make_unique<nmr_capture>();
    capture->capture = std::make_unique<nmr::SystemCapture>(target, handler, sound_seen_before);
    return capture.release();
  });
}

void nmr_capture_start(nmr_capture* capture) {
  if (capture != nullptr) capture->capture->start();
}

void nmr_capture_stop(nmr_capture* capture) {
  if (capture != nullptr) capture->capture->stop();
}

void nmr_capture_destroy(nmr_capture* capture) { delete capture; }
