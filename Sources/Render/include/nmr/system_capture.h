// Follows the system output for the overlay app: one SystemTap at a time, writing into a ring of
// its own, shown by a RenderView.
//
// The tap is rebuilt off the main thread, on a serial user-interactive queue, whenever the
// default output device changes, the device dies or changes its sample rate, or the tap's format
// changes (several changes within kSettleS make one rebuild; a failed start is retried a few
// times). Each rebuild stops the old tap,
// starts a new one into a new ring and then, on the main thread, gives the view the new ring and
// frees the old one, which the view no longer reads by then. Every outcome reaches the status
// handler on the main thread; a failed start leaves the view without a source (no silent
// fallback). App only (process taps need macOS 14.2 and the audio-capture permission).
//
// Until sound arrives, the capture also looks every SignalWatch::kCheckS at what came in and at
// whether another process plays on the device it follows, and reports a change of signal (a
// denied permission delivers exact zeros, not errors: nmr/signal_watch.h). That report repeats
// the latest start's status and `rebuilds`. Once sound has arrived it stops looking.
#pragma once

#ifdef __OBJC__
#import <AppKit/AppKit.h>
#include <CoreAudio/AudioHardware.h>

#include <nmr/render_view.h>
#include <nmr/signal_watch.h>

#include <cstdint>
#include <memory>

namespace nmr {

struct CaptureStatus {
  OSStatus status = noErr;     // of the step that failed, or noErr when capturing
  const char* failed_step = "";  // static storage
  double sample_rate = 0;
  uint32_t channels = 0;
  uint64_t rebuilds = 0;  // starts so far, this one included
  Signal signal = Signal::kUnknown;
};

class SystemCapture {
 public:
  static constexpr double kSettleS = 0.1;
  static constexpr uint32_t kRingFrames = 1 << 17;  // 2.7 s at 48 kHz

  using StatusHandler = void (^)(CaptureStatus status);

  // Main thread. Nothing runs until start(). `sound_seen_before`: an earlier run got sound, so
  // the permission is granted and the signal needs no watching.
  SystemCapture(NMR_OBJC(RenderView) * view, StatusHandler handler, bool sound_seen_before);
  // Main thread: stops the tap and waits for the capture queue.
  ~SystemCapture();
  SystemCapture(const SystemCapture&) = delete;
  SystemCapture& operator=(const SystemCapture&) = delete;

  void start();  // main thread; the tap starts on the capture queue (it may show the prompt)
  void stop();   // main thread; waits until the tap is down (or the permission prompt is answered)

 private:
  struct State;
  std::shared_ptr<State> state_;
};

}  // namespace nmr

#endif  // __OBJC__
