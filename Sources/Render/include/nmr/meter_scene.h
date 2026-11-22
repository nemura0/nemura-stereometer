// One meter view's frames: reads the source ring, paces it, analyzes and draws it.
//
// Each display frame the playhead (nmr/playhead.h) picks the source frames to draw, the analyzer
// maps them, and the meter renderer draws them with the trail decayed by the frame's real dt.
// The frame-rate governor watches for late frames (skipped by the link, or encoded after their
// target time; in Auto it steps down to 60 Hz) and the idle detector stops the view after the
// trail time plus 250 ms of silence: the scene draws one cleared frame and calls `on_idle`; the
// view then stops its display link and checks for sound at a low rate (soundArrived) to start it
// again. In the x86_64 slice the render thread runs with flush-to-zero and denormals-are-zero
// (the analyzer's filters decay into subnormals).
//
// Settings may be set from any thread; they take effect at the next frame the render thread can
// pick them up without waiting. The source is replaced while no frame is drawn (setSource).
// Everything else: render thread only.
#pragma once

#ifdef __OBJC__
#import <Metal/Metal.h>

#include <nmr/colormap.h>
#include <nmr/dsp.h>
#include <nmr/frame_rate.h>
#include <nmr/frame_ring.h>
#include <nmr/guides.h>
#include <nmr/idle.h>
#include <nmr/meter_renderer.h>
#include <nmr/playhead.h>
#include <nmr/render_loop.h>

#include <array>
#include <atomic>
#include <memory>
#include <mutex>
#include <vector>

namespace nmr {

struct MeterSettings {
  dsp::AnalyzerConfig analyzer{};
  double trail_s = 0.1;
  float brightness = 1;
  float point_size_pt = 2;
  float line_thickness_pt = 1.5f;
  uint32_t density = 2;
  DrawStyle draw = DrawStyle::kDots;
  PointShape shape = PointShape::kSoft;
  GuideLevel guides = GuideLevel::kSubtle;
  bool correlation = true;
  bool balance = true;
  bool readouts = false;
  MeterLook look{};
  colormap::Table colormap = defaultColormap();
  FrameRateChoice frame_rate = FrameRateChoice::kAuto;

  static colormap::Table defaultColormap() noexcept;
};

class MeterScene final : public FrameDrawer {
 public:
  static constexpr size_t kHistory = 240;       // correlation history entries
  static constexpr double kHistoryStepS = 1.0 / 60;
  static constexpr uint32_t kWakeFrames = 1024;  // what soundArrived() reads at a time

  MeterScene(id<MTLDevice> device, MTLPixelFormat format);
  [[nodiscard]] bool ready() const noexcept { return renderer_.ready(); }

  // Replaces the source at once: call it while no frame is being drawn (the loop stopped, or
  // inside RenderLoop::whilePaused), so the old ring can be freed when it returns. An invalid
  // ring: no source (silence).
  void setSource(FrameRingView ring, double sample_rate) noexcept;
  // Any thread; the next frame the render thread can take it without waiting.
  void setSettings(const MeterSettings& settings);

  // Called on the render thread, before the frame's commands are committed, with the run (see
  // restart()) they belong to: when the scene has gone idle (after its cleared frame), and when
  // the governor's rate changes. They must hand off (never stop the loop from inside). Set
  // before the loop starts.
  void setCallbacks(void (^on_idle)(uint64_t run), void (^on_rate)(float hz, uint64_t run));

  // Any thread, before the link (re)starts: the display's highest rate. Returns the rate to
  // start the link at.
  float prepareStart(float display_max_hz) noexcept;
  // Any thread: the link (re)starts. The next frame starts the trail, the rate count and the
  // idle timer over. Returns the new run's number (callbacks from older runs are stale).
  uint64_t restart() noexcept {
    return run_requested_.fetch_add(1, std::memory_order_acq_rel) + 1;
  }
  [[nodiscard]] float rate() const noexcept { return rate_.load(std::memory_order_relaxed); }
  // Any thread: whether a source or settings given since the last drawn frame are not drawn
  // yet (an idle report is then out of date).
  [[nodiscard]] bool changesPending() const noexcept {
    return changes_requested_.load(std::memory_order_acquire) !=
           changes_drawn_.load(std::memory_order_acquire);
  }
  // Any thread: every source frame before this one has been drawn or skipped.
  [[nodiscard]] uint64_t drawnFrames() const noexcept {
    return drawn_.load(std::memory_order_relaxed);
  }

  void drawFrame(id<CAMetalDrawable> drawable, const FrameTiming& timing) override;
  // Draws one frame into `target` (the drawable's texture, or offscreen). False: skipped
  // (idle with nothing new, or no free buffers).
  bool render(id<MTLCommandBuffer> commands, id<MTLTexture> target, const FrameTiming& timing,
              float scale);

  // Any thread, low rate, while idle: whether `ring` holds sound written since `seen` (then
  // set to the newest frame). Looks at everything still intact, kWakeFrames at a time;
  // `scratch` holds kWakeFrames stereo frames.
  static bool soundArrived(const FrameRingView& ring, uint64_t& seen, float* scratch) noexcept;

 private:
  struct Pending {
    bool has_settings = false;
    MeterSettings settings;
    float display_hz = 0;
  };
  void takePending() noexcept;
  void applySettings() noexcept;
  void pushHistory(double dt, float correlation) noexcept;
  void pace(const FrameTiming& timing) noexcept;
  uint32_t readSpan(double time) noexcept;  // the frame's samples into samples_; their count

  id<MTLCommandQueue> queue_;
  MeterRenderer renderer_;
  std::mutex pending_mutex_;
  std::unique_ptr<Pending> pending_;  // guarded by pending_mutex_
  void (^on_idle_)(uint64_t) = nil;
  void (^on_rate_)(float, uint64_t) = nil;
  std::atomic<float> rate_{60};
  std::atomic<FrameRateChoice> choice_{FrameRateChoice::kAuto};  // the newest setting
  std::atomic<bool> stepped_down_{false};  // the governor stepped down (until reconfigured)
  std::atomic<uint64_t> run_requested_{1};
  std::atomic<uint64_t> drawn_{0};
  std::atomic<uint64_t> changes_requested_{0};  // bumped by setSource and setSettings
  std::atomic<uint64_t> changes_drawn_{0};      // the count the last drawn frame showed
  std::atomic<float> start_display_hz_{0};      // the display rate prepareStart last saw

  // Render thread (and setSource, while no frame is drawn).
  MeterSettings settings_;
  FrameRingView ring_;
  double sample_rate_ = 48000;
  bool source_changed_ = false;
  float display_hz_ = 60;
  uint64_t run_ = 0;
  dsp::Analyzer analyzer_;
  Playhead playhead_;
  FrameRateGovernor governor_;
  IdleDetector idle_;
  Guides guides_{};
  std::vector<float> samples_;  // interleaved, Playhead::kMaxSpanS at the highest rate
  std::vector<dsp::Point> points_;
  std::vector<float> colors_;
  std::array<float, 2 * kHistory> history_{};  // each value twice: a contiguous window
  size_t history_head_ = 0;
  size_t history_count_ = 0;
  double history_clock_ = 0;
  bool clear_next_ = true;
  bool changed_ = false;          // new settings or source: an idle scene draws once more
  uint64_t changes_taken_ = 0;    // changes_requested_ when the pending state was last taken
  bool idle_unreported_ = false;  // gone idle; its cleared frame not drawn yet
  bool last_late_ = false;        // the previous frame was encoded after its target time
};

}  // namespace nmr

#endif  // __OBJC__
