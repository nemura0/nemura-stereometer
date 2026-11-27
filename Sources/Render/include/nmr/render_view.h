// An NSView hosting a CAMetalLayer whose meter frames (nmr/meter_scene.h) are produced on a
// dedicated render thread. The view runs its render loop only while it is in a window,
// unhidden, not occluded and non-empty, and stops it otherwise (0 fps, no GPU work). It also
// stops when the scene goes idle (silence for the trail time plus 250 ms) and then looks for
// sound every 100 ms on a user-interactive queue, starting again when some arrives. The loop
// runs at the scene's rate (the display's maximum, or what the frame_rate setting and the
// governor make of it).
#pragma once

#ifdef __OBJC__
#import <AppKit/AppKit.h>

#include <nmr/objc_names.h>

#ifdef __cplusplus
#include <nmr/frame_ring.h>
#include <nmr/meter_scene.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@interface NMR_OBJC(RenderView) : NSView

// `background` is premultiplied RGBA in 0...1. Alpha 1 makes the layer opaque (plugin editors);
// alpha 0 gives a fully transparent background (the overlay app).
- (instancetype)initWithFrame:(NSRect)frame
                   background:(const float[_Nonnull 4])background NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;

#ifdef __cplusplus
// Main thread. The ring the meter reads (it must outlive the view or the next setSource), and
// its sample rate. An invalid ring: no source.
- (void)setSource:(nmr::FrameRingView)ring sampleRate:(double)sampleRate;
// Main thread. Takes effect at the next frame; the background comes from initWithFrame.
- (void)setSettings:(const nmr::MeterSettings&)settings;
// Any thread. How the meter's frames reached the screen since the last reset (diagnostics).
@property(nonatomic, readonly) nmr::FrameStats::Summary frameStats;
- (void)resetFrameStats;
#endif

// Whether the render thread is currently running (for tests and diagnostics).
@property(nonatomic, readonly) BOOL isRendering;
// Whether the meter stopped for silence and is waiting for sound.
@property(nonatomic, readonly) BOOL isIdle;

@end

NS_ASSUME_NONNULL_END

#endif  // __OBJC__
