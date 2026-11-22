#import <nmr/meter_scene.h>

#import <QuartzCore/QuartzCore.h>

#include <nmr/layout.h>
#include <nmr/scope_style.h>

#include <algorithm>
#include <cstring>

#if defined(__x86_64__)
#include <xmmintrin.h>
#endif

namespace nmr {
namespace {

constexpr double kMaxHistoryDtS = 0.25;
constexpr auto kMaxSpanFrames = static_cast<uint32_t>(Playhead::kMaxSpanS * Playhead::kMaxRate);
static_assert(kMaxSpanFrames <= MeterRenderer::kMaxPoints);

// Whether two configurations put the same samples in the same places (and colors): if not,
// the trail is cleared.
bool sameMapping(const dsp::AnalyzerConfig& a, const dsp::AnalyzerConfig& b) noexcept {
  return a.map.scale == b.map.scale && a.map.log_range_db == b.map.log_range_db &&
         a.map.half == b.map.half && a.map.orientation == b.map.orientation &&
         a.color == b.color;
}

// The analyzer's filters decay into subnormals; x86_64 handles them slowly.
void flushDenormals() noexcept {
#if defined(__x86_64__)
  _mm_setcsr(_mm_getcsr() | 0x8040);  // FTZ | DAZ
#endif
}

uint64_t readableFrames(const FrameRingView& ring) noexcept {
  if (!ring.valid() || ring.capacity() <= kMaxWriteChunk) return 0;
  return ring.capacity() - kMaxWriteChunk;
}

}  // namespace

colormap::Table MeterSettings::defaultColormap() noexcept {
  const colormap::Builtin* builtin = colormap::findBuiltin(colormap::kDefaultKey);
  return builtin != nullptr ? colormap::table(builtin->stops) : colormap::Table{};
}

MeterScene::MeterScene(id<MTLDevice> device, MTLPixelFormat format)
    : queue_([device newCommandQueue]),
      renderer_(device, format),
      pending_(std::make_unique<Pending>()),
      samples_(2 * size_t{kMaxSpanFrames}),
      points_(kMaxSpanFrames),
      colors_(kMaxSpanFrames) {
  analyzer_.prepare(sample_rate_);
  playhead_.prepare(sample_rate_, 0);
  idle_.prepare(settings_.trail_s);
  applySettings();
  governor_.configure(settings_.frame_rate, display_hz_);
}

void MeterScene::setSource(FrameRingView ring, double sample_rate) noexcept {
  ring_ = ring;
  sample_rate_ = sample_rate;
  source_changed_ = true;  // set up by the next frame (the render thread's objects)
  changes_requested_.fetch_add(1, std::memory_order_acq_rel);
}

void MeterScene::setSettings(const MeterSettings& settings) {
  if (choice_.exchange(settings.frame_rate, std::memory_order_relaxed) != settings.frame_rate) {
    stepped_down_.store(false, std::memory_order_relaxed);  // a new choice starts over
  }
  const std::lock_guard lock(pending_mutex_);
  pending_->has_settings = true;
  pending_->settings = settings;
  changes_requested_.fetch_add(1, std::memory_order_acq_rel);  // under the lock: see takePending
}

float MeterScene::prepareStart(float display_max_hz) noexcept {
  FrameRateGovernor expected;
  expected.configure(choice_.load(std::memory_order_relaxed), display_max_hz);
  auto hz = static_cast<float>(expected.rate());
  // A new display rate reconfigures the governor, which forgets a step-down.
  const float last_display = start_display_hz_.exchange(display_max_hz, std::memory_order_relaxed);
  if (last_display != display_max_hz) stepped_down_.store(false, std::memory_order_relaxed);
  if (stepped_down_.load(std::memory_order_relaxed)) {
    hz = std::min(hz, static_cast<float>(FrameRateGovernor::kFallbackHz));
  }
  rate_.store(hz, std::memory_order_relaxed);
  {
    const std::lock_guard lock(pending_mutex_);
    pending_->display_hz = display_max_hz;
  }
  return hz;
}

void MeterScene::setCallbacks(void (^on_idle)(uint64_t), void (^on_rate)(float, uint64_t)) {
  on_idle_ = on_idle;
  on_rate_ = on_rate;
}

// Never waits: a frame that finds a setter busy picks the change up at the next one. Only the
// copy happens under the lock.
void MeterScene::takePending() noexcept {
  std::unique_lock lock(pending_mutex_, std::try_to_lock);
  if (!lock.owns_lock()) return;
  // Every source and settings change requested so far is in hand now (setSource ran between
  // frames, setSettings bumps the count under this lock).
  changes_taken_ = changes_requested_.load(std::memory_order_acquire);
  const bool has_settings = pending_->has_settings;
  const float display_hz = pending_->display_hz;
  const FrameRateChoice old_choice = settings_.frame_rate;
  const dsp::AnalyzerConfig old_analyzer = settings_.analyzer;
  if (has_settings) settings_ = pending_->settings;  // a plain copy: no allocation
  pending_->has_settings = false;
  pending_->display_hz = 0;
  lock.unlock();

  bool reconfigure = false;
  if (has_settings) {
    if (!sameMapping(settings_.analyzer, old_analyzer)) clear_next_ = true;
    reconfigure = settings_.frame_rate != old_choice;
    applySettings();
    changed_ = true;
  }
  if (display_hz > 0 && display_hz != display_hz_) {
    display_hz_ = display_hz;
    reconfigure = true;
  }
  if (reconfigure) governor_.configure(settings_.frame_rate, display_hz_);
}

void MeterScene::applySettings() noexcept {
  analyzer_.configure(settings_.analyzer);
  renderer_.setColormap(settings_.colormap);
  idle_.setTrail(settings_.trail_s);
  guides_ = guides(settings_.guides, settings_.analyzer.map);
}

// History values every kHistoryStepS of display time (a frame can push several).
void MeterScene::pushHistory(double dt, float correlation) noexcept {
  if (!(dt > 0)) return;
  history_clock_ += std::min(dt, kMaxHistoryDtS);
  for (size_t pushed = 0; history_clock_ >= kHistoryStepS && pushed < kHistory; ++pushed) {
    history_clock_ -= kHistoryStepS;
    history_[history_head_] = correlation;
    history_[history_head_ + kHistory] = correlation;
    history_head_ = (history_head_ + 1) % kHistory;
    history_count_ = std::min(history_count_ + 1, kHistory);
  }
}

// Late frames count against the rate (the governor counts the ones the link skipped); the
// scene reports when the rate changes.
void MeterScene::pace(const FrameTiming& timing) noexcept {
  const float current = rate_.load(std::memory_order_relaxed);
  governor_.frame(timing.target_time, last_late_);
  last_late_ = false;
  stepped_down_.store(governor_.steppedDown(), std::memory_order_relaxed);
  const auto hz = static_cast<float>(governor_.rate());
  if (hz == current) return;
  rate_.store(hz, std::memory_order_relaxed);
  if (on_rate_ != nil) on_rate_(hz, run_);
}

uint32_t MeterScene::readSpan(double time) noexcept {
  if (!ring_.valid()) return 0;
  const FrameSpan span = playhead_.advance(time, ring_.framesWritten());
  drawn_.store(span.end, std::memory_order_relaxed);
  const auto count = static_cast<uint32_t>(std::min<uint64_t>(span.size(), kMaxSpanFrames));
  if (count == 0) return 0;
  const uint64_t first = span.end - count;
  const uint64_t intact = ring_.read(first, count, samples_.data());
  if (intact >= span.end) return 0;
  const auto lost = static_cast<uint32_t>(intact - first);  // overwritten while copying
  if (lost > 0) {
    std::memmove(samples_.data(), samples_.data() + 2 * size_t{lost},
                 2 * size_t{count - lost} * sizeof(float));
  }
  return count - lost;
}

bool MeterScene::render(id<MTLCommandBuffer> commands, id<MTLTexture> target,
                        const FrameTiming& timing, float scale) {
  flushDenormals();
  takePending();
  const double time = timing.target_time;
  if (source_changed_) {
    source_changed_ = false;
    analyzer_.prepare(sample_rate_);
    analyzer_.configure(settings_.analyzer);
    playhead_.prepare(sample_rate_, readableFrames(ring_));
    drawn_.store(0, std::memory_order_relaxed);
    clear_next_ = true;
    changed_ = true;
  }
  const uint64_t run = run_requested_.load(std::memory_order_acquire);
  if (run != run_) {
    run_ = run;
    governor_.restart();
    idle_.wake(time);
    idle_unreported_ = false;
    clear_next_ = true;
  }
  pace(timing);

  const uint32_t count = readSpan(time);
  const bool sound = IdleDetector::hasSound(samples_.data(), count);
  if (idle_.idle() && !idle_unreported_) {
    if (!sound && !changed_) return false;  // idle and drawn: nothing new
    idle_.wake(time);  // sound, or a change to show (it goes idle again after the hold)
    if (sound) clear_next_ = true;
  }
  changed_ = false;
  if (idle_.frame(time, sound)) idle_unreported_ = true;
  if (count > 0) analyzer_.process(samples_.data(), count, points_.data(), colors_.data());
  pushHistory(timing.dt, analyzer_.correlation());

  const dsp::MapParams& map = settings_.analyzer.map;
  MeterFrame frame;
  if (!idle_unreported_) {
    frame.points = {points_.data(), count};
    frame.colors = {colors_.data(), count};
  }
  frame.style = scopeStyle({.dt = timing.dt,
                            .sample_rate = sample_rate_,
                            .trail_s = settings_.trail_s,
                            .brightness = settings_.brightness,
                            .point_size_pt = settings_.point_size_pt,
                            .line_thickness_pt = settings_.line_thickness_pt,
                            .density = settings_.density,
                            .scale = scale,
                            .style = settings_.draw});
  frame.draw = settings_.draw;
  frame.shape = settings_.shape;
  frame.clear = clear_next_ || idle_unreported_;
  frame.glow = settings_.glow;
  frame.layout = layout({.width = static_cast<float>(target.width),
                         .height = static_cast<float>(target.height),
                         .scale = scale,
                         .half = map.half,
                         .correlation = settings_.correlation,
                         .balance = settings_.balance,
                         .readouts = settings_.readouts});
  frame.guides = &guides_;
  frame.correlation = analyzer_.correlation();
  frame.balance = analyzer_.balance();
  frame.correlation_history = {history_.data() + history_head_ + kHistory - history_count_,
                               history_count_};
  frame.look = settings_.look;

  if (!renderer_.encode(commands, target, frame, scale)) return false;
  clear_next_ = false;
  changes_drawn_.store(changes_taken_, std::memory_order_release);
  if (idle_unreported_) {
    idle_unreported_ = false;
    if (on_idle_ != nil) on_idle_(run_);
  }
  return true;
}

void MeterScene::drawFrame(id<CAMetalDrawable> drawable, const FrameTiming& timing) {
  if (drawable == nil || queue_ == nil) return;
  id<MTLCommandBuffer> commands = [queue_ commandBuffer];
  const auto scale = static_cast<float>(drawable.layer.contentsScale);
  if (!render(commands, drawable.texture, timing, scale)) return;
  [commands presentDrawable:drawable];
  [commands commit];
  last_late_ = CACurrentMediaTime() > timing.target_time;  // encoded after its deadline
}

bool MeterScene::soundArrived(const FrameRingView& ring, uint64_t& seen, float* scratch) noexcept {
  if (!ring.valid() || scratch == nullptr) return false;
  const uint64_t written = ring.framesWritten();
  const uint64_t since = std::min(seen, written);  // a new source counts from its start
  seen = written;
  const uint64_t readable = readableFrames(ring);
  uint64_t first = written - std::min(written - since, readable);
  while (first < written) {
    const auto count = static_cast<uint32_t>(std::min<uint64_t>(kWakeFrames, written - first));
    const uint64_t end = first + count;
    const uint64_t intact = ring.read(first, count, scratch);
    // Frames overwritten while reading are lost; the newest are still to come.
    if (intact < end && IdleDetector::hasSound(scratch + 2 * (intact - first), end - intact)) {
      return true;
    }
    first = end;
  }
  return false;
}

}  // namespace nmr
