#include "nmr_corec.h"

#import <AppKit/AppKit.h>
#import <nmr/render_view.h>
#include <nmr/version.h>

#if !__has_feature(objc_arc)
#error "Sources/CoreC is compiled with ARC (-fobjc-arc) in every build"
#endif

const char* nmr_version(void) { return nmr::versionString(); }

const char* nmr_product_name(void) { return nmr::productName(); }

void* nmr_render_view_create(double width, double height, const float rgba[4]) {
  static constexpr float kTransparent[4] = {0, 0, 0, 0};
  NMR_OBJC(RenderView)* view =
      [[NMR_OBJC(RenderView) alloc] initWithFrame:NSMakeRect(0, 0, width, height)
                                       background:rgba != nullptr ? rgba : kTransparent];
  return (__bridge_retained void*)view;
}
