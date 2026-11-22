#import <nmr/glyph_atlas.h>

#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

#include <os/log.h>

#include <algorithm>
#include <cmath>
#include <vector>

namespace nmr {

namespace {

constexpr uint32_t kMargin = 1;  // clear pixels around each cell's ink
constexpr size_t kCount = kReadoutGlyphs.size();

// The glyph set as CoreText shapes it (so the font's tabular digits are the ones used), each
// glyph with the font of its run and where its ink sits from the pen.
struct Shaped {
  std::array<CGGlyph, kCount> ids{};
  std::array<CTFontRef, kCount> fonts{};  // owned by the line
  std::array<CGRect, kCount> bounds{};
  std::array<CGFloat, kCount> advances{};
  std::array<CGFloat, kCount> offsets{};  // the ink's shift right of the pen
  CFTypeRef line = nullptr;
  ~Shaped() {
    if (line != nullptr) CFRelease(line);
  }
};

// The system font with tabular digits, sized so its digits are `cap_px` tall (null on failure).
CTFontRef readoutFont(float cap_px) {
  CTFontRef probe = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 100, nullptr);
  if (probe == nullptr) return nullptr;
  const CGFloat cap_per_point = CTFontGetCapHeight(probe) / 100;
  CTFontRef font = nullptr;
  if (cap_per_point > 0) {
    NSDictionary* tabular = @{
      (__bridge NSString*)kCTFontOpenTypeFeatureTag : @"tnum",
      (__bridge NSString*)kCTFontOpenTypeFeatureValue : @1,
    };
    NSDictionary* attributes =
        @{(__bridge NSString*)kCTFontFeatureSettingsAttribute : @[ tabular ]};
    CTFontDescriptorRef descriptor =
        CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attributes);
    font = CTFontCreateCopyWithAttributes(probe, cap_px / cap_per_point, nullptr, descriptor);
    CFRelease(descriptor);
  }
  CFRelease(probe);
  return font;
}

// Shapes kReadoutGlyphs in one line, without ligatures (each character keeps one glyph) or
// kerning.
bool shape(CTFontRef font, Shaped& out) {
  NSString* text = [[NSString alloc] initWithBytes:kReadoutGlyphs.data()
                                            length:kCount
                                          encoding:NSASCIIStringEncoding];
  NSDictionary* attributes = @{
    (__bridge NSString*)kCTFontAttributeName : (__bridge id)font,
    (__bridge NSString*)kCTLigatureAttributeName : @0,
    (__bridge NSString*)kCTKernAttributeName : @0,  // advances free of their neighbours
  };
  NSAttributedString* string = [[NSAttributedString alloc] initWithString:text
                                                               attributes:attributes];
  CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
  if (line == nullptr) return false;
  out.line = line;
  std::array<bool, kCount> found{};
  NSArray* runs = (__bridge NSArray*)CTLineGetGlyphRuns(line);
  for (id object in runs) {
    CTRunRef run = (__bridge CTRunRef)object;
    auto* run_font = static_cast<CTFontRef>(
        CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName));
    const CFIndex n = CTRunGetGlyphCount(run);
    std::vector<CGGlyph> ids(static_cast<size_t>(n));
    std::vector<CFIndex> indices(static_cast<size_t>(n));
    std::vector<CGSize> advances(static_cast<size_t>(n));
    CTRunGetGlyphs(run, CFRangeMake(0, n), ids.data());
    CTRunGetStringIndices(run, CFRangeMake(0, n), indices.data());
    CTRunGetAdvances(run, CFRangeMake(0, n), advances.data());
    for (CFIndex g = 0; g < n; ++g) {
      const auto i = static_cast<size_t>(indices[static_cast<size_t>(g)]);
      if (i >= kCount || found[i] || run_font == nullptr) return false;
      found[i] = true;
      out.ids[i] = ids[static_cast<size_t>(g)];
      out.fonts[i] = run_font;
      out.advances[i] = advances[static_cast<size_t>(g)].width;
      CTFontGetBoundingRectsForGlyphs(run_font, kCTFontOrientationHorizontal, &out.ids[i],
                                      &out.bounds[i], 1);
    }
  }
  return std::all_of(found.begin(), found.end(), [](bool f) { return f; });
}

// Digits one width, even where the font has no tabular figures: each takes the widest digit's
// advance, its ink centered in it.
void evenDigits(Shaped& s) {
  CGFloat widest = 0;
  for (size_t i = 0; i < kCount; ++i) {
    if (kReadoutGlyphs[i] >= '0' && kReadoutGlyphs[i] <= '9') {
      widest = std::max(widest, s.advances[i]);
    }
  }
  for (size_t i = 0; i < kCount; ++i) {
    if (kReadoutGlyphs[i] < '0' || kReadoutGlyphs[i] > '9') continue;
    s.offsets[i] = (widest - s.advances[i]) / 2;
    s.advances[i] = widest;
  }
}

id<MTLTexture> upload(id<MTLDevice> device, const std::vector<uint8_t>& pixels, uint32_t width,
                      uint32_t height) {
  MTLTextureDescriptor* d = [[MTLTextureDescriptor alloc] init];
  d.pixelFormat = MTLPixelFormatR8Unorm;
  d.width = width;
  d.height = height;
  d.usage = MTLTextureUsageShaderRead;
  d.storageMode = device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
  id<MTLTexture> texture = [device newTextureWithDescriptor:d];
  [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
             mipmapLevel:0
               withBytes:pixels.data()
             bytesPerRow:width];
  return texture;
}

struct Drawn {
  id<MTLTexture> texture;
  uint32_t cell_width = 0;
  uint32_t cell_height = 0;
  uint32_t pen_x = 0;
  uint32_t baseline = 0;
  std::array<GlyphAtlas::Glyph, kCount> glyphs{};
};

// Draws each glyph into its cell and uploads the cells, side by side, as one texture.
bool drawCells(id<MTLDevice> device, CTFontRef font, Shaped& shaped, Drawn& out) {
  evenDigits(shaped);
  // One cell size that holds every glyph's ink and advance, the pen at the same place in each.
  CGFloat left = 0;
  CGFloat right = 0;
  for (size_t i = 0; i < kCount; ++i) {
    left = std::min(left, CGRectGetMinX(shaped.bounds[i]) + shaped.offsets[i]);
    right = std::max({right, CGRectGetMaxX(shaped.bounds[i]) + shaped.offsets[i],
                      shaped.advances[i]});
  }
  const auto pen_x = static_cast<uint32_t>(std::ceil(-left)) + kMargin;
  const auto ascent = static_cast<uint32_t>(std::ceil(CTFontGetAscent(font)));
  const auto descent = static_cast<uint32_t>(std::ceil(CTFontGetDescent(font)));
  const uint32_t cell_width = pen_x + static_cast<uint32_t>(std::ceil(right)) + kMargin;
  const uint32_t cell_height = ascent + descent + 2 * kMargin;
  const uint32_t width = cell_width * static_cast<uint32_t>(kCount);

  std::vector<uint8_t> pixels(size_t{width} * cell_height, 0);
  CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
  CGContextRef context = CGBitmapContextCreate(pixels.data(), width, cell_height, 8, width, gray,
                                               kCGImageAlphaNone);
  CGColorSpaceRelease(gray);
  if (context == nullptr) return false;
  CGContextSetGrayFillColor(context, 1, 1);
  CGContextSetShouldAntialias(context, true);
  CGContextSetShouldSmoothFonts(context, false);
  for (size_t i = 0; i < kCount; ++i) {
    // CoreGraphics counts up from the bottom row; the baseline sits above the descent.
    const CGPoint pen =
        CGPointMake(i * cell_width + pen_x + shaped.offsets[i], descent + kMargin);
    CTFontDrawGlyphs(shaped.fonts[i], &shaped.ids[i], &pen, 1, context);
    out.glyphs[i] = {static_cast<uint32_t>(i) * cell_width,
                     static_cast<float>(shaped.advances[i])};
  }
  CGContextFlush(context);
  CGContextRelease(context);

  out.texture = upload(device, pixels, width, cell_height);
  out.cell_width = cell_width;
  out.cell_height = cell_height;
  out.pen_x = pen_x;
  out.baseline = kMargin + ascent;  // rows from the top
  return out.texture != nil;
}

}  // namespace

const GlyphAtlas::Glyph* GlyphAtlas::glyph(char c) const noexcept {
  const size_t i = kReadoutGlyphs.find(c);
  return i == std::string_view::npos || texture_ == nil ? nullptr : &glyphs_[i];
}

float GlyphAtlas::width(std::string_view text) const noexcept {
  float sum = 0;
  for (const char c : text) {
    if (const Glyph* g = glyph(c)) sum += g->advance;
  }
  return sum;
}

void GlyphAtlas::clear() noexcept {
  texture_ = nil;
  cap_px_ = 0;
}

bool GlyphAtlas::build(id<MTLDevice> device, float cap_px) {
  clear();
  if (device == nil || !(cap_px > 0 && cap_px <= GlyphAtlas::kMaxCapPx)) return false;
  @autoreleasepool {  // the render thread may have no pool of its own
    CTFontRef font = readoutFont(cap_px);
    Shaped shaped;
    Drawn drawn;
    const bool ok =
        font != nullptr && shape(font, shaped) && drawCells(device, font, shaped, drawn);
    if (font != nullptr) CFRelease(font);
    if (!ok) {
      os_log_error(OS_LOG_DEFAULT, "nmr: the readout glyphs could not be made");
      return false;
    }
    texture_ = drawn.texture;
    cap_px_ = cap_px;
    cell_width_ = drawn.cell_width;
    cell_height_ = drawn.cell_height;
    pen_x_ = drawn.pen_x;
    baseline_ = drawn.baseline;
    glyphs_ = drawn.glyphs;
    return true;
  }
}

}  // namespace nmr
