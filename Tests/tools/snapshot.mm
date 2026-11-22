// Renders a WAV through the analyzer and the meter renderer, offscreen, and writes the last
// frame as a PNG (premultiplied alpha kept). For visual checks and calibration, not shipped.
//
//   nmr_snapshot <in.wav> <out.png> [--mode goniometer|goniometer_log|half|half_log|lissajous]
//       [--at SECONDS] [--size PX] [--scale S] [--fps F] [--draw dots|lines] [--trail MS]
//       [--density N] [--point PT] [--line PT] [--shape soft|circle|square] [--brightness PCT]
//       [--glow PCT] [--guides off|subtle|full] [--color frequency|solid|amplitude|midside]
//       [--colormap KEY] [--stops T:RRGGBB,...] [--background RRGGBBAA] [--meters on|off]
//       [--readouts on|off] [--ring RRGGBBAA] [--guide-strong RRGGBBAA] [--guide-weak RRGGBBAA]
//       [--whiten N] [--glow-color RRGGBB] [--glow-warn RRGGBB]
//
// --stops replaces the colormap with these stops (positions 0 … 1, ascending). --ring draws the
// 0 dBFS ring in that color. --glow-warn mixes the glow color toward it as the correlation goes
// negative (nmr::phaseWarning), frame by frame.
// It draws the second before --at at --fps, each frame taking the next rate / fps samples (an
// ideal playhead), so the trail is settled.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>

#include <nmr/colormap.h>
#include <nmr/dsp.h>
#include <nmr/guides.h>
#include <nmr/layout.h>
#include <nmr/meter_bars.h>
#include <nmr/meter_renderer.h>
#include <nmr/scope_style.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace {

using ScopePoint = nmr::dsp::Point;

constexpr double kSettleS = 1;
constexpr size_t kHistory = 240;

struct Wav {
  double rate = 0;
  std::vector<float> samples;  // interleaved stereo
};

uint32_t u32(const uint8_t* p) { return p[0] | p[1] << 8 | p[2] << 16 | uint32_t{p[3]} << 24; }
uint16_t u16(const uint8_t* p) { return static_cast<uint16_t>(p[0] | p[1] << 8); }

// 32-bit float stereo only (what nmr_make_test_wav writes).
std::optional<Wav> readWav(const char* path) {
  std::ifstream file(path, std::ios::binary);
  const std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)), {});
  if (bytes.size() < 12 || std::memcmp(bytes.data(), "RIFF", 4) != 0 ||
      std::memcmp(bytes.data() + 8, "WAVE", 4) != 0) {
    return std::nullopt;
  }
  Wav wav;
  bool format_ok = false;
  for (size_t at = 12; at + 8 <= bytes.size();) {
    const uint8_t* chunk = bytes.data() + at;
    const size_t size = u32(chunk + 4);
    if (at + 8 + size > bytes.size()) break;
    if (std::memcmp(chunk, "fmt ", 4) == 0 && size >= 16) {
      format_ok = u16(chunk + 8) == 3 && u16(chunk + 10) == 2 && u16(chunk + 22) == 32;
      wav.rate = u32(chunk + 12);
    } else if (std::memcmp(chunk, "data", 4) == 0 && format_ok) {
      wav.samples.resize(size / sizeof(float));
      std::memcpy(wav.samples.data(), chunk + 8, wav.samples.size() * sizeof(float));
    }
    at += 8 + size + (size & 1);
  }
  if (!format_ok || wav.samples.empty()) return std::nullopt;
  return wav;
}

using Options = std::map<std::string, std::string>;

std::string option(const Options& o, const std::string& key, const std::string& fallback) {
  const auto it = o.find(key);
  return it == o.end() ? fallback : it->second;
}

double number(const Options& o, const std::string& key, double fallback) {
  const auto it = o.find(key);
  return it == o.end() ? fallback : std::atof(it->second.c_str());
}

// `digits` hex digits, or nothing.
std::optional<uint32_t> hexValue(const std::string& hex, size_t digits) {
  if (hex.size() != digits || hex.find_first_not_of("0123456789abcdefABCDEF") != hex.npos) {
    return std::nullopt;
  }
  return static_cast<uint32_t>(std::strtoul(hex.c_str(), nullptr, 16));
}

[[noreturn]] void badOption(const std::string& what) {
  std::fprintf(stderr, "nmr_snapshot: %s\n", what.c_str());
  std::exit(2);
}

// RRGGBBAA.
nmr::Premultiplied premultiplied(const std::string& hex) {
  const std::optional<uint32_t> parsed = hexValue(hex, 8);
  if (!parsed) badOption("colors with alpha are RRGGBBAA, not " + hex);
  const uint32_t v = *parsed;
  const float a = (v & 0xff) / 255.0f;
  return {((v >> 24) & 0xff) / 255.0f * a, ((v >> 16) & 0xff) / 255.0f * a,
          ((v >> 8) & 0xff) / 255.0f * a, a};
}

// RRGGBB.
std::array<float, 3> rgb(const std::string& hex) {
  const std::optional<uint32_t> parsed = hexValue(hex, 6);
  if (!parsed) badOption("colors are RRGGBB, not " + hex);
  const uint32_t v = *parsed;
  return {((v >> 16) & 0xff) / 255.0f, ((v >> 8) & 0xff) / 255.0f, (v & 0xff) / 255.0f};
}

// "0:FFFFFF,0.5:8993FF,1:E03C60": positions 0 … 1, ascending (empty when malformed).
std::vector<nmr::colormap::Stop> parseStops(const std::string& list) {
  std::vector<nmr::colormap::Stop> stops;
  size_t from = 0;
  while (from < list.size()) {
    const size_t end = std::min(list.find(',', from), list.size());
    const std::string item = list.substr(from, end - from);
    const size_t colon = item.find(':');
    if (colon == std::string::npos) return {};
    char* rest = nullptr;
    const float position = std::strtof(item.c_str(), &rest);
    const std::optional<uint32_t> v = hexValue(item.substr(colon + 1), 6);
    if (rest != item.c_str() + colon || !v || !(position >= 0 && position <= 1) ||
        (!stops.empty() && position < stops.back().position)) {
      return {};
    }
    const auto byte = [v](int shift) { return static_cast<uint8_t>((*v >> shift) & 0xff); };
    stops.push_back({position, {byte(16), byte(8), byte(0), 255}});
    from = end + 1;
  }
  return stops;
}

bool writePng(const char* path, const void* bgra, uint32_t width, uint32_t height) {
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGDataProviderRef data = CGDataProviderCreateWithData(nullptr, bgra, size_t{width} * height * 4,
                                                        nullptr);
  CGImageRef image = CGImageCreate(width, height, 8, 32, size_t{width} * 4, space,
                                   static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little) |
                                       static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst),
                                   data, nullptr, false, kCGRenderingIntentDefault);
  NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
  CGImageDestinationRef out = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)url, CFSTR("public.png"), 1, nullptr);
  bool ok = image != nullptr && out != nullptr;
  if (ok) {
    CGImageDestinationAddImage(out, image, nullptr);
    ok = CGImageDestinationFinalize(out);
  }
  if (out != nullptr) CFRelease(out);
  CGImageRelease(image);
  CGDataProviderRelease(data);
  CGColorSpaceRelease(space);
  return ok;
}

int usage() {
  std::fprintf(stderr, "usage: nmr_snapshot <in.wav> <out.png> [--option value ...]\n"
                       "  (see Tests/tools/snapshot.mm for the options)\n");
  return 2;
}

}  // namespace

int main(int argc, char** argv) {
  @autoreleasepool {
    if (argc < 3 || (argc - 3) % 2 != 0) return usage();
    Options o;
    for (int i = 3; i + 1 < argc; i += 2) {
      if (std::strncmp(argv[i], "--", 2) != 0) return usage();
      o[argv[i] + 2] = argv[i + 1];
    }
    const std::optional<Wav> wav = readWav(argv[1]);
    if (!wav) {
      std::fprintf(stderr, "nmr_snapshot: %s is not a 32-bit float stereo WAV\n", argv[1]);
      return 1;
    }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) {
      std::fprintf(stderr, "nmr_snapshot: no Metal device\n");
      return 1;
    }

    const std::string mode = option(o, "mode", "goniometer");
    nmr::dsp::AnalyzerConfig config;
    config.map.scale = mode.find("_log") != std::string::npos ? nmr::dsp::Scale::kLog
                                                               : nmr::dsp::Scale::kLinear;
    config.map.half = mode.rfind("half", 0) == 0;
    const bool lissajous = mode == "lissajous";
    if (lissajous) config.map.orientation = nmr::dsp::Orientation::kLeftRight;
    const std::string color = option(o, "color", "frequency");
    config.color = color == "solid"       ? nmr::dsp::ColorMode::kSolid
                   : color == "amplitude" ? nmr::dsp::ColorMode::kAmplitude
                   : color == "midside"   ? nmr::dsp::ColorMode::kMidSide
                                          : nmr::dsp::ColorMode::kFrequency;
    nmr::dsp::Analyzer analyzer;
    analyzer.prepare(wav->rate);
    analyzer.configure(config);

    const auto size = static_cast<uint32_t>(number(o, "size", 600));
    const auto scale = static_cast<float>(number(o, "scale", 2));
    const double fps = number(o, "fps", 120);
    const bool meters = option(o, "meters", "on") == "on";
    const nmr::Layout layout = nmr::layout({.width = static_cast<float>(size),
                                            .height = static_cast<float>(size),
                                            .scale = scale,
                                            .half = config.map.half,
                                            .correlation = meters,
                                            .balance = meters,
                                            .readouts = option(o, "readouts", "off") == "on"});
    const std::string guide_level = option(o, "guides", "subtle");
    const nmr::Guides guides = nmr::guides(guide_level == "off"    ? nmr::GuideLevel::kOff
                                           : guide_level == "full" ? nmr::GuideLevel::kFull
                                                                   : nmr::GuideLevel::kSubtle,
                                           config.map, o.count("ring") != 0);

    const std::string draw = option(o, "draw", lissajous ? "lines" : "dots");
    const std::string shape = option(o, "shape", "soft");
    nmr::ScopeStyleInput style_input{
        .dt = 1 / fps,
        .sample_rate = wav->rate,
        .trail_s = number(o, "trail", 100) / 1000,
        .brightness = static_cast<float>(number(o, "brightness", 100) / 100),
        .point_size_pt = static_cast<float>(number(o, "point", 2)),
        .line_thickness_pt = static_cast<float>(number(o, "line", 1.5)),
        .density = static_cast<uint32_t>(number(o, "density", 2)),
        .scale = scale,
        .style = draw == "lines" ? nmr::DrawStyle::kLines : nmr::DrawStyle::kDots};
    if (style_input.style == nmr::DrawStyle::kLines) style_input.density = 1;

    nmr::MeterFrame frame;
    frame.layout = layout;
    frame.guides = &guides;
    frame.style = nmr::scopeStyle(style_input);
    frame.draw = style_input.style;
    frame.glow = static_cast<float>(number(o, "glow", 0) / 100);
    frame.shape = shape == "circle"   ? nmr::PointShape::kCircle
                  : shape == "square" ? nmr::PointShape::kSquare
                                      : nmr::PointShape::kSoft;
    frame.look.background = premultiplied(option(o, "background", "08080CFF"));
    frame.look.solid = config.color == nmr::dsp::ColorMode::kSolid;
    if (o.count("ring") != 0) frame.look.ring = premultiplied(o.at("ring"));
    if (o.count("guide-strong") != 0) frame.look.guide_strong = premultiplied(o.at("guide-strong"));
    if (o.count("guide-weak") != 0) frame.look.guide_weak = premultiplied(o.at("guide-weak"));
    frame.look.whiten = static_cast<float>(number(o, "whiten", nmr::MeterRenderer::kWhiten));
    const std::array<float, 3> glow_color = rgb(option(o, "glow-color", "FFFFFF"));
    const std::optional<std::array<float, 3>> glow_warn =
        o.count("glow-warn") != 0 ? std::optional(rgb(o.at("glow-warn"))) : std::nullopt;
    frame.look.glow_color = glow_color;

    nmr::MeterRenderer renderer(device, MTLPixelFormatBGRA8Unorm);
    if (!renderer.ready()) {
      std::fprintf(stderr, "nmr_snapshot: the renderer could not be set up\n");
      return 1;
    }
    const std::string map_key = option(o, "colormap", std::string(nmr::colormap::kDefaultKey));
    const nmr::colormap::Builtin* map = nmr::colormap::findBuiltin(map_key);
    if (map == nullptr) {
      std::fprintf(stderr, "nmr_snapshot: no built-in colormap %s\n", map_key.c_str());
      return 1;
    }
    if (o.count("stops") != 0) {
      const std::vector<nmr::colormap::Stop> stops = parseStops(o.at("stops"));
      if (stops.empty()) {
        std::fprintf(stderr, "nmr_snapshot: --stops wants T:RRGGBB,... (T 0 … 1, ascending)\n");
        return 1;
      }
      renderer.setColormap(nmr::colormap::table(stops));
    } else {
      renderer.setColormap(nmr::colormap::table(map->stops));
    }

    MTLTextureDescriptor* d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:size
                                                          height:size
                                                       mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget;
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device newTextureWithDescriptor:d];
    id<MTLBuffer> readback = [device newBufferWithLength:size_t{size} * size * 4
                                                 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [device newCommandQueue];

    const uint64_t frames_total = wav->samples.size() / 2;
    const double end_s = std::min(number(o, "at", 5), frames_total / wav->rate);
    const auto end = static_cast<uint64_t>(end_s * wav->rate);
    uint64_t at = static_cast<uint64_t>(std::max(0.0, end_s - kSettleS) * wav->rate);
    std::vector<ScopePoint> points;
    std::vector<float> colors;
    std::vector<float> history;
    double frame_end = static_cast<double>(at);
    frame.clear = true;
    while (at < end) {
      frame_end = std::min(frame_end + wav->rate / fps, static_cast<double>(end));
      const auto count = static_cast<uint32_t>(static_cast<uint64_t>(frame_end) - at);
      points.resize(count);
      colors.resize(count);
      analyzer.process(wav->samples.data() + at * 2, count, points.data(), colors.data());
      at += count;
      history.push_back(analyzer.correlation());
      if (history.size() > kHistory) history.erase(history.begin());
      frame.points = points;
      frame.colors = colors;
      frame.correlation = analyzer.correlation();
      frame.balance = analyzer.balance();
      frame.correlation_history = history;
      if (glow_warn) {
        const float w = nmr::phaseWarning(frame.correlation);
        for (size_t c = 0; c < 3; ++c) {
          frame.look.glow_color[c] = glow_color[c] + ((*glow_warn)[c] - glow_color[c]) * w;
        }
      }
      id<MTLCommandBuffer> commands = [queue commandBuffer];
      if (!renderer.encode(commands, target, frame, scale)) {
        std::fprintf(stderr, "nmr_snapshot: a frame was skipped\n");
        return 1;
      }
      frame.clear = false;
      if (at >= end) {
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        [blit copyFromTexture:target
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(size, size, 1)
                            toBuffer:readback
                   destinationOffset:0
              destinationBytesPerRow:size_t{size} * 4
            destinationBytesPerImage:size_t{size} * size * 4];
        [blit endEncoding];
      }
      [commands commit];
      [commands waitUntilCompleted];
    }
    if (!writePng(argv[2], readback.contents, size, size)) {
      std::fprintf(stderr, "nmr_snapshot: could not write %s\n", argv[2]);
      return 1;
    }
    std::printf("%s\n", argv[2]);
    return 0;
  }
}
