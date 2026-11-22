#include <nmr/system_capture.h>

#include <nmr/frame_ring.h>
#include <nmr/product_config.h>
#include <nmr/system_tap.h>
#include <os/log.h>

#include <atomic>
#include <ctime>
#include <utility>
#include <vector>

#include <unistd.h>

#if !__has_feature(objc_arc)
#error "Sources/Render is compiled with ARC (-fobjc-arc) in every build"
#endif

namespace nmr {

namespace {

constexpr AudioObjectPropertyAddress globalAddress(AudioObjectPropertySelector selector) {
  return {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}

constexpr AudioObjectPropertyAddress kDefaultOutput =
    globalAddress(kAudioHardwarePropertyDefaultOutputDevice);
constexpr AudioObjectPropertyAddress kDeviceAlive =
    globalAddress(kAudioDevicePropertyDeviceIsAlive);
constexpr AudioObjectPropertyAddress kDeviceRate =
    globalAddress(kAudioDevicePropertyNominalSampleRate);
constexpr AudioObjectPropertyAddress kTapFormat = globalAddress(kAudioTapPropertyFormat);

double uptimeS() { return static_cast<double>(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9; }

os_log_t captureLog() {
  static os_log_t log = os_log_create(NMR_APP_BUNDLE_ID, "capture");
  return log;
}

void addListener(AudioObjectID object, const AudioObjectPropertyAddress& address,
                 dispatch_queue_t queue, AudioObjectPropertyListenerBlock block) {
  const OSStatus status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block);
  if (status != noErr) {
    os_log_error(captureLog(), "listener for '%{public}.4s' on %u failed: %d",
                 reinterpret_cast<const char*>(&address.mSelector), object, (int)status);
  }
}

}  // namespace

// Blocks capture a C++ reference as a reference, so every block below captures a weak_ptr copy
// made from weak_from_this(), never a reference parameter that dies with the caller.
//
// stop() bumps `epoch` before it waits for the queue, and again on the queue. Work on the queue
// reads the epoch when it begins, so whatever it delivers after a stop() carries an old epoch and
// is dropped on main (the second bump catches work that began between the two).
struct SystemCapture::State : std::enable_shared_from_this<State> {
  static constexpr uint32_t kRetries = 3;  // failed starts retried, kRetryS apart
  static constexpr double kRetryS = 0.5;

  dispatch_queue_t queue;
  __weak NMR_OBJC(RenderView) * view;
  StatusHandler handler;
  std::atomic<uint64_t> epoch{0};

  // Capture queue only.
  bool running = false;
  uint64_t rebuilds = 0;
  uint64_t scheduled = 0;  // the latest scheduled rebuild; earlier ones are skipped
  uint32_t failures = 0;   // consecutive failed starts
  std::shared_ptr<LocalFrameRing> ring;
  std::unique_ptr<SystemTap> tap;
  AudioObjectID watched_device = kAudioObjectUnknown;
  AudioObjectID watched_tap = kAudioObjectUnknown;
  AudioObjectPropertyListenerBlock on_change;
  SignalWatch signal_watch;
  dispatch_source_t checker = nil;  // looks at the signal until sound arrives
  std::vector<float> scratch = std::vector<float>(size_t{kMaxWriteChunk} * 2);
  uint64_t checked = 0;  // frames of `ring` already looked at
  CaptureStatus last;    // the latest report, sent again when the signal changes

  // Main thread only: the ring the view reads, kept until it reads another.
  std::shared_ptr<LocalFrameRing> shown;

  // A change was seen: rebuild once things have settled for kSettleS.
  void changed() {
    failures = 0;
    schedule(kSettleS);
  }

  void schedule(double delay_s) {
    const uint64_t mine = ++scheduled;
    const std::weak_ptr<State> weak = weak_from_this();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(delay_s * NSEC_PER_SEC)),
                   queue, ^{
                     const std::shared_ptr<State> self = weak.lock();
                     if (!self || !self->running || self->scheduled != mine) return;
                     self->rebuild(self->epoch.load(std::memory_order_acquire));
                   });
  }

  void watch(AudioObjectID device, AudioObjectID tap_object) {
    watched_device = device;
    watched_tap = tap_object;
    if (device != kAudioObjectUnknown) {
      addListener(device, kDeviceAlive, queue, on_change);
      addListener(device, kDeviceRate, queue, on_change);
    }
    if (tap_object != kAudioObjectUnknown) addListener(tap_object, kTapFormat, queue, on_change);
  }

  void unwatch() {
    if (watched_device != kAudioObjectUnknown) {
      AudioObjectRemovePropertyListenerBlock(watched_device, &kDeviceAlive, queue, on_change);
      AudioObjectRemovePropertyListenerBlock(watched_device, &kDeviceRate, queue, on_change);
    }
    if (watched_tap != kAudioObjectUnknown) {
      AudioObjectRemovePropertyListenerBlock(watched_tap, &kTapFormat, queue, on_change);
    }
    watched_device = kAudioObjectUnknown;
    watched_tap = kAudioObjectUnknown;
  }

  // Stops the old tap before the new one starts, so the old ring takes no more writes. `at` is
  // the epoch when this work began.
  void rebuild(uint64_t at) {
    unwatch();
    tap.reset();
    std::shared_ptr<LocalFrameRing> fresh;
    std::unique_ptr<SystemTap> next;
    try {
      fresh = std::make_shared<LocalFrameRing>(kRingFrames);
      next = std::make_unique<SystemTap>(fresh->view());
    } catch (...) {
      ring = nullptr;
      deliver(at, nullptr,
              {.status = kAudioHardwareUnspecifiedError, .failed_step = "capture memory",
               .rebuilds = ++rebuilds});
      return;
    }
    const OSStatus status = next->start();
    const CaptureStatus report{.status = status,
                               .failed_step = next->failedStep(),
                               .sample_rate = next->format().sample_rate,
                               .channels = next->format().channels,
                               .rebuilds = ++rebuilds};
    if (status == noErr) {
      failures = 0;
      watch(next->outputDevice(), next->tapObject());
      tap = std::move(next);
      ring = fresh;
      checked = 0;
      signal_watch.restart();  // zeros counted so far came from the old tap
      startChecking();
    } else {
      ring = nullptr;
      fresh = nullptr;  // no source: the view shows that nothing arrives
      // A device mid-change (a Bluetooth profile switch, say) can fail once; try again a few
      // times. The default-output listener stays, so a later device change also retries.
      if (++failures <= kRetries) schedule(kRetryS);
    }
    deliver(at, fresh, report);
  }

  void startChecking() {
    if (checker != nil || signal_watch.done()) return;
    checker = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    const auto period = static_cast<int64_t>(SignalWatch::kCheckS * NSEC_PER_SEC);
    dispatch_source_set_timer(checker, dispatch_time(DISPATCH_TIME_NOW, period),
                              static_cast<uint64_t>(period), static_cast<uint64_t>(period / 5));
    const std::weak_ptr<State> weak = weak_from_this();
    dispatch_source_set_event_handler(checker, ^{
      if (const std::shared_ptr<State> self = weak.lock()) self->checkSignal();
    });
    dispatch_resume(checker);
  }

  void stopChecking() {
    if (checker == nil) return;
    dispatch_source_cancel(checker);
    checker = nil;
  }

  void checkSignal() {
    if (!running || ring == nullptr || tap == nullptr) return;
    const uint64_t at = epoch.load(std::memory_order_acquire);
    const Signal before = signal_watch.signal();
    const Samples samples = SignalWatch::scan(ring->view(), checked, scratch.data());
    const bool others = samples == Samples::kZeros &&
                        processesPlayOutput(getpid(), tap->outputDevice());
    const Signal now = signal_watch.check(uptimeS(), samples, others);
    if (signal_watch.done()) stopChecking();
    if (now == before) return;
    last.signal = now;
    const CaptureStatus report = last;
    const std::weak_ptr<State> weak = weak_from_this();
    dispatch_async(dispatch_get_main_queue(), ^{
      const std::shared_ptr<State> self = weak.lock();
      if (!self || self->epoch.load(std::memory_order_acquire) != at) return;
      if (self->handler != nil) self->handler(report);
    });
  }

  void deliver(uint64_t at, std::shared_ptr<LocalFrameRing> fresh, CaptureStatus report) {
    report.signal = signal_watch.signal();
    last = report;
    const std::weak_ptr<State> weak = weak_from_this();
    dispatch_async(dispatch_get_main_queue(), ^{
      const std::shared_ptr<State> self = weak.lock();
      if (!self || self->epoch.load(std::memory_order_acquire) != at) return;
      NMR_OBJC(RenderView)* target = self->view;
      [target setSource:fresh ? fresh->view() : FrameRingView{} sampleRate:report.sample_rate];
      self->shown = fresh;  // the old ring is freed here, after the view let go of it
      if (self->handler != nil) self->handler(report);
    });
  }
};

SystemCapture::SystemCapture(NMR_OBJC(RenderView) * view, StatusHandler handler,
                             bool sound_seen_before)
    : state_(std::make_shared<State>()) {
  state_->signal_watch = SignalWatch(sound_seen_before);
  dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
      DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
  state_->queue = dispatch_queue_create("nmr.capture", attributes);
  state_->view = view;
  state_->handler = handler;
  const std::weak_ptr<State> weak = state_;
  state_->on_change = ^(UInt32, const AudioObjectPropertyAddress*) {
    if (const std::shared_ptr<State> self = weak.lock()) self->changed();
  };
}

SystemCapture::~SystemCapture() { stop(); }

void SystemCapture::start() {
  const std::weak_ptr<State> weak = state_;
  dispatch_async(state_->queue, ^{
    const std::shared_ptr<State> self = weak.lock();
    if (!self || self->running) return;  // already started: its delivery is on its way
    self->running = true;
    self->failures = 0;
    addListener(kAudioObjectSystemObject, kDefaultOutput, self->queue, self->on_change);
    self->rebuild(self->epoch.load(std::memory_order_acquire));
  });
}

// Waits for the queue: while the first start shows the permission prompt, that is until the
// prompt is answered (the tap cannot be interrupted).
void SystemCapture::stop() {
  state_->epoch.fetch_add(1, std::memory_order_acq_rel);  // drops deliveries still on their way
  State* state = state_.get();
  dispatch_sync(state->queue, ^{
    // Again on the queue: work that began between the first bump and this block read the new
    // epoch, so its deliveries would pass; this bump comes after all of it.
    state->epoch.fetch_add(1, std::memory_order_acq_rel);
    if (!state->running) return;
    state->running = false;
    AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &kDefaultOutput,
                                           state->queue, state->on_change);
    state->unwatch();
    state->stopChecking();
    state->tap.reset();  // AudioDeviceStop, then the IO proc, the aggregate and the tap
    state->ring = nullptr;  // `shown` keeps it until the view lets go
  });
  NMR_OBJC(RenderView)* view = state->view;
  [view setSource:FrameRingView{} sampleRate:0];
  state->shown = nullptr;
}

}  // namespace nmr
