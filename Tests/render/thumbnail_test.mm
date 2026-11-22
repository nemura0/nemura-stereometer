// Mode thumbnails: the meter's look drawn offscreen from the test mix.
#import <Metal/Metal.h>

#include <nmr/meter_scene.h>
#include <nmr/thumbnail.h>

#include <doctest/doctest.h>

#include <algorithm>
#include <cstdint>
#include <vector>

using nmr::MeterSettings;
using nmr::ThumbnailRenderer;

namespace {

constexpr uint32_t kSide = 96;

// The share of pixels with any light (BGRA, premultiplied: alpha counts).
double lit(const std::vector<uint8_t>& bgra) {
  size_t count = 0;
  for (size_t i = 0; i + 3 < bgra.size(); i += 4) {
    if (std::max({bgra[i], bgra[i + 1], bgra[i + 2]}) > 24) ++count;
  }
  return static_cast<double>(count) / (bgra.size() / 4);
}

MeterSettings white() {
  MeterSettings settings;
  settings.look.solid = true;
  settings.look.solid_color = {1, 1, 1};
  settings.correlation = false;  // the bars under the scope would count as trace
  settings.balance = false;
  return settings;
}

}  // namespace

TEST_CASE("thumbnail: draws the trace of the test mix") {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (device == nil) {
    MESSAGE("no Metal device: skipped");
    return;
  }
  ThumbnailRenderer renderer(device);
  REQUIRE(renderer.ready());
  std::vector<uint8_t> bgra(kSide * kSide * 4, 0xAB);
  REQUIRE(renderer.render(white(), kSide, kSide, 1, bgra.data()));
  const double share = lit(bgra);
  CHECK(share > 0.02);  // a trace, not a dot
  CHECK(share < 0.8);   // and not a wash
  // Top row first: the mono axis points up, so the upper half holds more of the trace.
  const std::vector<uint8_t> top(bgra.begin(), bgra.begin() + bgra.size() / 2);
  const std::vector<uint8_t> bottom(bgra.begin() + bgra.size() / 2, bgra.end());
  CHECK(lit(top) > lit(bottom));
}

TEST_CASE("thumbnail: the same look draws the same pixels, another look others") {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (device == nil) {
    MESSAGE("no Metal device: skipped");
    return;
  }
  ThumbnailRenderer renderer(device);
  REQUIRE(renderer.ready());
  std::vector<uint8_t> first(kSide * kSide * 4), again(first.size()), lines(first.size());
  MeterSettings settings = white();
  REQUIRE(renderer.render(settings, kSide, kSide, 1, first.data()));
  REQUIRE(renderer.render(settings, kSide, kSide, 1, again.data()));
  CHECK(first == again);
  settings.draw = nmr::DrawStyle::kLines;
  REQUIRE(renderer.render(settings, kSide, kSide, 1, lines.data()));
  CHECK(first != lines);
}

TEST_CASE("thumbnail: refuses sizes it cannot draw") {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (device == nil) {
    MESSAGE("no Metal device: skipped");
    return;
  }
  ThumbnailRenderer renderer(device);
  std::vector<uint8_t> bgra(4);
  CHECK_FALSE(renderer.render(white(), 0, 1, 1, bgra.data()));
  CHECK_FALSE(renderer.render(white(), 1, 0, 1, bgra.data()));
  CHECK_FALSE(renderer.render(white(), ThumbnailRenderer::kMaxSide + 1, 1, 1, bgra.data()));
  CHECK_FALSE(renderer.render(white(), 1, 1, 0, bgra.data()));
  CHECK_FALSE(renderer.render(white(), 1, 1, 1, nullptr));
}
