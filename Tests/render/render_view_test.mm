// The view on screen: a small window, the real display link.
#import <AppKit/AppKit.h>

#import <nmr/render_view.h>

#include <doctest/doctest.h>

#include <vector>

namespace {

// Handles events and the main queue until `done` or `seconds` pass.
bool spinUntil(bool (^done)(void), double seconds) {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!done()) {
    if ([deadline timeIntervalSinceNow] <= 0) return false;
    NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                        untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
                                           inMode:NSDefaultRunLoopMode
                                          dequeue:YES];
    if (event != nil) [NSApp sendEvent:event];
  }
  return true;
}

// CI's macOS VMs ("Apple Paravirtual device") draw so slowly, and present so few drawables,
// that idling can take longer than a test waits. Timing checks are kept for real GPUs.
bool virtualGpu() {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  return device == nil || [device.name rangeOfString:@"Paravirtual"].location != NSNotFound;
}

// A wait that must succeed on a real GPU and may time out on a VM.
void checkOnRealGpu(bool ok, const char* what) {
  if (virtualGpu()) {
    WARN_MESSAGE(ok, what << " timed out on a virtual GPU");
  } else {
    CHECK_MESSAGE(ok, what);
  }
}

}  // namespace

TEST_CASE("render view: stops in silence and starts again when sound arrives") {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  [NSApp finishLaunching];
  NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 160, 160)
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.releasedWhenClosed = NO;
  const float background[4] = {0, 0, 0, 1};
  NMR_OBJC(RenderView)* view =
      [[NMR_OBJC(RenderView) alloc] initWithFrame:NSMakeRect(0, 0, 160, 160)
                                       background:background];
  window.contentView = view;
  [window orderFrontRegardless];

  if (!spinUntil(^bool { return view.isRendering == YES; }, 3)) {
    // No window server (a headless runner): reported as a warning, not a pass.
    WARN_MESSAGE(false, "the window never became visible (occlusion "
                            << window.occlusionState << ", screen " << (window.screen != nil)
                            << "): skipped");
    [window close];
    return;
  }
  // No source: silence. Idle after the trail plus 250 ms. The waits return as soon as the view
  // gets there; they are long because a loaded CI runner can draw a few frames a second.
  const bool idle = spinUntil(^bool { return view.isIdle == YES; }, 10);
  checkOnRealGpu(idle, "idle in silence");
  if (idle) CHECK_FALSE(view.isRendering);

  const nmr::LocalFrameRing ring(1 << 15);
  [view setSource:ring.view() sampleRate:48000];  // a new source: it looks, then stops again
  CHECK(view.isRendering);
  checkOnRealGpu(spinUntil(^bool { return view.isIdle == YES; }, 10),
                 "idle again after a new source");

  std::vector<float> sound(2 * 512, 0.1f);
  nmr::FrameRingView writer = ring.view();
  writer.write(sound.data(), 512);
  CHECK(spinUntil(^bool { return view.isIdle == NO; }, 5));
  CHECK(view.isRendering);

  [view setSource:{} sampleRate:48000];  // the ring goes away first
  [window close];
}

TEST_CASE("render view: counts the frames that reach the screen") {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  [NSApp finishLaunching];
  NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 160, 160)
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.releasedWhenClosed = NO;
  const float background[4] = {0, 0, 0, 1};
  NMR_OBJC(RenderView)* view =
      [[NMR_OBJC(RenderView) alloc] initWithFrame:NSMakeRect(0, 0, 160, 160)
                                       background:background];
  window.contentView = view;
  [window orderFrontRegardless];
  if (!spinUntil(^bool { return view.isRendering == YES; }, 3)) {
    WARN_MESSAGE(false, "the window never became visible: skipped");
    [window close];
    return;
  }
  const bool virtual_gpu = virtualGpu();
  // Silence: it draws for the trail plus 250 ms, then idles; every frame it drew is reported.
  checkOnRealGpu(spinUntil(^bool { return view.isIdle == YES; }, 10), "idle in silence");
  CHECK(spinUntil(^bool { return view.frameStats.frames > 0; }, 2));  // handlers run late
  const nmr::FrameStats::Summary drawn = view.frameStats;
  INFO("frames " << drawn.frames << ", presented " << drawn.presented << ", period "
                 << drawn.period_ms << " ms, p50 " << drawn.p50_ms << " ms");
  if (virtual_gpu) {
    // CI's macOS VMs ("Apple Paravirtual device") present few drawables or none: each frame
    // is still reported, as presented or as dropped.
    CHECK(drawn.presented + drawn.dropped >= drawn.frames);
  } else {
    CHECK(drawn.presented > 3);
    CHECK(drawn.period_ms >= 1000.0 / 240);
    CHECK(drawn.period_ms <= 1000.0 / 30);
    CHECK(drawn.intervals > 0);
  }
  [view resetFrameStats];
  CHECK(view.frameStats.frames == 0);
  [window close];
}
