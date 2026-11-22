// The scene end to end, offscreen: a ring in, frames paced, analyzed and drawn.
#import <Metal/Metal.h>

#include <nmr/layout.h>
#include <nmr/meter_scene.h>

#include <doctest/doctest.h>

#include <algorithm>
#include <cmath>
#include <vector>

using nmr::FrameTiming;
using nmr::LocalFrameRing;
using nmr::MeterScene;
using nmr::MeterSettings;
using ScopePoint = nmr::dsp::Point;

namespace {

constexpr uint32_t kSize = 200;
constexpr double kRate = 48000;

class Stage {
 public:
  Stage() : device_(MTLCreateSystemDefaultDevice()) {
    if (device_ == nil) return;
    queue_ = [device_ newCommandQueue];
    scene_ = std::make_unique<MeterScene>(device_, MTLPixelFormatBGRA8Unorm);
    MTLTextureDescriptor* d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:kSize
                                                          height:kSize
                                                       mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget;
    d.storageMode = MTLStorageModePrivate;
    target_ = [device_ newTextureWithDescriptor:d];
    readback_ = [device_ newBufferWithLength:kSize * kSize * 4
                                     options:MTLResourceStorageModeShared];
    MeterSettings settings;
    settings.look.solid = true;
    settings.look.solid_color = {1, 1, 1};
    settings.brightness = 3;
    scene_->setSettings(settings);
  }

  [[nodiscard]] bool available() const { return device_ != nil; }
  MeterScene& scene() { return *scene_; }

  // One display frame at `time`, then the pixels read back.
  bool frame(double time, double dt = 1.0 / 60) {
    FrameTiming timing{.target_time = time, .present_time = time, .dt = dt};
    id<MTLCommandBuffer> commands = [queue_ commandBuffer];
    const bool drawn = scene_->render(commands, target_, timing, 1);
    id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
    [blit copyFromTexture:target_
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(kSize, kSize, 1)
                        toBuffer:readback_
               destinationOffset:0
          destinationBytesPerRow:kSize * 4
        destinationBytesPerImage:kSize * kSize * 4];
    [blit endEncoding];
    [commands commit];
    [commands waitUntilCompleted];
    return drawn;
  }

  // The brightest channel where a scope point lands (the scene's default layout).
  [[nodiscard]] float at(ScopePoint p) const {
    const nmr::Layout layout = nmr::layout({.width = kSize, .height = kSize, .scale = 1});
    const nmr::Rect& s = layout.scope;
    const float x = std::round(s.x);
    const float y = std::round(s.y);
    const float w = std::round(s.x + s.width) - x;
    const float h = std::round(s.y + s.height) - y;
    const float half = nmr::MeterRenderer::kFullScale / 2;
    const auto px = static_cast<size_t>(x + (0.5f + half * p.x) * w);
    const auto py = static_cast<size_t>(y + (0.5f - half * p.y) * h);
    const auto* bytes = static_cast<const uint8_t*>(readback_.contents) + (py * kSize + px) * 4;
    return std::max({bytes[0], bytes[1], bytes[2]}) / 255.0f;
  }

 private:
  id<MTLDevice> device_;
  id<MTLCommandQueue> queue_;
  std::unique_ptr<MeterScene> scene_;
  id<MTLTexture> target_;
  id<MTLBuffer> readback_;
};

void writeDc(nmr::FrameRingView ring, float left, float right, uint32_t frames) {
  std::vector<float> block(size_t{frames} * 2);
  for (uint32_t i = 0; i < frames; ++i) {
    block[2 * i] = left;
    block[2 * i + 1] = right;
  }
  ring.write(block.data(), frames);
}

}  // namespace

#define REQUIRE_GPU(s)                         \
  do {                                         \
    if (!(s).available()) {                    \
      MESSAGE("no Metal device: skipped");     \
      return;                                  \
    }                                          \
    REQUIRE((s).scene().ready());              \
  } while (false)

TEST_CASE("meter scene: draws what the source plays") {
  Stage s;
  REQUIRE_GPU(s);
  const LocalFrameRing ring(1 << 15);
  s.scene().setSource(ring.view(), kRate);
  double time = 1;
  for (int i = 0; i < 40; ++i, time += 1.0 / 60) {
    writeDc(ring.view(), 0.5f, 0.5f, 800);  // mono at -6 dB: (0, 0.5)
    REQUIRE(s.frame(time));
  }
  CHECK(s.at({0, 0.5f}) > 0.3f);
  CHECK(s.at({0.3f, 0.5f}) < 0.02f);
  CHECK(s.at({-0.3f, -0.5f}) < 0.02f);
}

TEST_CASE("meter scene: settings take effect at the next frame") {
  Stage s;
  REQUIRE_GPU(s);
  REQUIRE(s.frame(1));
  const ScopePoint on_circle{0.5f, std::sqrt(0.75f)};  // 30° off the mono axis
  CHECK(s.at(on_circle) < 0.02f);                       // subtle guides: no unit circle
  MeterSettings settings;
  settings.guides = nmr::GuideLevel::kFull;
  s.scene().setSettings(settings);
  REQUIRE(s.frame(1 + 1.0 / 60));
  CHECK(s.at(on_circle) > 0.03f);
}

TEST_CASE("meter scene: goes idle once after the trail plus 250 ms of silence") {
  Stage s;
  REQUIRE_GPU(s);
  __block int idles = 0;
  __block double idle_at = 0;
  __block double now = 1;
  __block uint64_t idle_run = 0;
  const uint64_t run = s.scene().restart();
  s.scene().setCallbacks(^(uint64_t r) {
    ++idles;
    idle_at = now;
    idle_run = r;
  }, nil);
  for (; now < 2; now += 1.0 / 60) s.frame(now);
  CHECK(idles == 1);
  CHECK(idle_run == run);
  CHECK_FALSE(s.frame(now));  // idle: nothing to draw until sound arrives
  CHECK(idle_at - 1 >= MeterSettings{}.trail_s + nmr::IdleDetector::kHoldS - 1e-6);
  CHECK(idle_at - 1 < MeterSettings{}.trail_s + nmr::IdleDetector::kHoldS + 0.05);
}

TEST_CASE("meter scene: sound arriving while idle is noticed") {
  const LocalFrameRing ring(1 << 15);
  std::vector<float> scratch(MeterScene::kWakeFrames * 2);
  uint64_t seen = 0;
  CHECK_FALSE(MeterScene::soundArrived(ring.view(), seen, scratch.data()));
  writeDc(ring.view(), 0, 0, 2000);
  CHECK_FALSE(MeterScene::soundArrived(ring.view(), seen, scratch.data()));
  writeDc(ring.view(), 0.1f, 0, 300);
  CHECK(MeterScene::soundArrived(ring.view(), seen, scratch.data()));
  CHECK_FALSE(MeterScene::soundArrived(ring.view(), seen, scratch.data()));  // nothing new
  CHECK_FALSE(MeterScene::soundArrived({}, seen, scratch.data()));            // no source

  // A burst followed by more silence than one read holds is still found.
  writeDc(ring.view(), 0.1f, 0, 300);
  writeDc(ring.view(), 0, 0, 3 * MeterScene::kWakeFrames);
  CHECK(MeterScene::soundArrived(ring.view(), seen, scratch.data()));
  // And a burst in the middle of a long stretch of silence.
  writeDc(ring.view(), 0, 0, 2 * MeterScene::kWakeFrames);
  writeDc(ring.view(), 0.1f, 0, 100);
  writeDc(ring.view(), 0, 0, 2 * MeterScene::kWakeFrames);
  CHECK(MeterScene::soundArrived(ring.view(), seen, scratch.data()));
  // So is sound from before `seen` was last set, as far back as the caller asks.
  seen = ring.view().framesWritten() - 2 * MeterScene::kWakeFrames - 100;
  CHECK(MeterScene::soundArrived(ring.view(), seen, scratch.data()));
}

TEST_CASE("meter scene: the idle frame is cleared, and sound brings the trace back") {
  Stage s;
  REQUIRE_GPU(s);
  const ScopePoint kOffAxis{-0.15f, 0.35f};
  const LocalFrameRing ring(1 << 15);
  s.scene().setSource(ring.view(), kRate);
  double time = 1;
  for (int i = 0; i < 20; ++i, time += 1.0 / 60) {
    writeDc(ring.view(), 0.5f, 0.2f, 800);  // (−0.15, 0.35): off the guides
    s.frame(time);
  }
  REQUIRE(s.at(kOffAxis) > 0.3f);
  // Silence: the trail fades, and the idle frame clears what is left.
  __block bool idle = false;
  s.scene().setCallbacks(^(uint64_t) { idle = true; }, nil);
  for (int i = 0; i < 60 && !idle; ++i, time += 1.0 / 60) {
    writeDc(ring.view(), 0, 0, 800);
    s.frame(time);
  }
  REQUIRE(idle);
  CHECK(s.at(kOffAxis) < 0.02f);
  writeDc(ring.view(), 0, 0, 800);
  CHECK_FALSE(s.frame(time));
  time += 1.0 / 60;
  for (int i = 0; i < 10; ++i, time += 1.0 / 60) {
    writeDc(ring.view(), 0.5f, 0.2f, 800);  // (−0.15, 0.35): off the guides
    s.frame(time);
  }
  CHECK(s.at(kOffAxis) > 0.3f);
}

TEST_CASE("meter scene: new settings are drawn while idle") {
  Stage s;
  REQUIRE_GPU(s);
  __block bool idle = false;
  s.scene().setCallbacks(^(uint64_t) { idle = true; }, nil);
  double time = 1;
  for (; time < 2 && !idle; time += 1.0 / 60) s.frame(time);
  REQUIRE(idle);
  REQUIRE_FALSE(s.frame(time));
  CHECK_FALSE(s.scene().changesPending());
  MeterSettings settings;
  settings.guides = nmr::GuideLevel::kFull;
  s.scene().setSettings(settings);
  CHECK(s.scene().changesPending());  // an idle report from before this is out of date
  CHECK(s.frame(time + 1.0 / 60));
  CHECK_FALSE(s.scene().changesPending());
  CHECK(s.at({0.5f, std::sqrt(0.75f)}) > 0.03f);  // the unit circle
}

TEST_CASE("meter scene: the start rate follows the setting and the display") {
  Stage s;
  REQUIRE_GPU(s);
  CHECK(s.scene().prepareStart(120) == 120);
  MeterSettings settings;
  settings.frame_rate = nmr::FrameRateChoice::k30;
  s.scene().setSettings(settings);
  CHECK(s.scene().prepareStart(120) == 30);
  settings.frame_rate = nmr::FrameRateChoice::k120;
  s.scene().setSettings(settings);
  CHECK(s.scene().prepareStart(60) == 60);
  CHECK(s.scene().restart() < s.scene().restart());
  const LocalFrameRing ring(1 << 15);
  s.scene().setSource(ring.view(), kRate);
  CHECK(s.scene().changesPending());
}

TEST_CASE("meter scene: in Auto, late frames step the rate down to 60 Hz") {
  Stage s;
  REQUIRE_GPU(s);
  __block float rate = 0;
  s.scene().setCallbacks(nil, ^(float hz, uint64_t) { rate = hz; });
  CHECK(s.scene().prepareStart(120) == 120);
  const LocalFrameRing ring(1 << 15);
  s.scene().setSource(ring.view(), kRate);
  double time = 1;
  s.scene().restart();
  for (int i = 0; i < 120 * 4; ++i) {
    writeDc(ring.view(), 0.2f, 0.1f, 400);
    const double step = i % 20 == 19 ? 3.0 / 120 : 1.0 / 120;  // a missed frame or two, often
    time += step;
    s.frame(time, step);
  }
  CHECK(rate == 60);
  CHECK(s.scene().rate() == 60);
}
