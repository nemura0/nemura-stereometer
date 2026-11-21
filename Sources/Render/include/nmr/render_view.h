// An NSView hosting a CAMetalLayer whose frames are produced on a dedicated render thread.
// The view starts its render loop only while it is in a window, unhidden, not occluded and
// non-empty, and stops it otherwise (0 fps, no GPU work).
#pragma once

#ifdef __OBJC__
#import <AppKit/AppKit.h>

#include <nmr/objc_names.h>

NS_ASSUME_NONNULL_BEGIN

@interface NMR_OBJC(RenderView) : NSView

// `background` is premultiplied RGBA in 0...1. Alpha 1 makes the layer opaque (plugin editors);
// alpha 0 gives a fully transparent background (the overlay app).
- (instancetype)initWithFrame:(NSRect)frame
                   background:(const float[_Nonnull 4])background NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;

// Whether the render thread is currently running (for tests and diagnostics).
@property(nonatomic, readonly) BOOL isRendering;

@end

NS_ASSUME_NONNULL_END

#endif  // __OBJC__
