#include <nmr/system_tap.h>

#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>
#include <nmr/product_config.h>

#include <cstring>

#if !__has_feature(objc_arc)
#error "Sources/Render is compiled with ARC (-fobjc-arc) in every build"
#endif

namespace nmr {

namespace {

constexpr uint32_t kFloatBytes = sizeof(float);

template <typename T>
OSStatus readProperty(AudioObjectID object, AudioObjectPropertySelector selector, T& value) {
  const AudioObjectPropertyAddress address{selector, kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
  UInt32 size = sizeof(T);
  return AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &value);
}

// Returns a +0 NSString (ARC-managed) for a CFString-valued property, or nil.
NSString* readStringProperty(AudioObjectID object, AudioObjectPropertySelector selector,
                             OSStatus& status) {
  CFStringRef value = nullptr;
  status = readProperty(object, selector, value);
  if (status != noErr || value == nullptr) return nil;
  return (__bridge_transfer NSString*)value;
}

}  // namespace

OSStatus SystemTap::fail(const char* step, OSStatus status) noexcept {
  failed_step_ = step;
  stop();
  return status != noErr ? status : static_cast<OSStatus>(kAudioHardwareUnspecifiedError);
}

OSStatus SystemTap::start() noexcept {
  if (isRunning()) return noErr;
  failed_step_ = "";
  if (!ring_.valid()) return fail("ring", kAudioHardwareIllegalOperationError);

  @autoreleasepool {
    // The default output device provides the aggregate's clock.
    AudioObjectID output = kAudioObjectUnknown;
    OSStatus status =
        readProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, output);
    if (status != noErr || output == kAudioObjectUnknown) {
      return fail("default output device", status);
    }
    NSString* output_uid = readStringProperty(output, kAudioDevicePropertyDeviceUID, status);
    if (output_uid == nil) return fail("output device UID", status);

    // Global stereo tap of every process. Private: only this process sees it. Unmuted: the user
    // keeps hearing everything.
    CATapDescription* description =
        [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
    description.name = @NMR_PRODUCT_NAME " capture";
    description.UUID = [NSUUID UUID];
    description.privateTap = YES;
    description.muteBehavior = CATapUnmuted;
    // Blocks while the audio-capture permission prompt is open.
    status = AudioHardwareCreateProcessTap(description, &tap_);
    if (status != noErr) return fail("AudioHardwareCreateProcessTap", status);

    NSString* tap_uid = readStringProperty(tap_, kAudioTapPropertyUID, status);
    if (tap_uid == nil) return fail("tap UID", status);

    AudioStreamBasicDescription asbd{};
    status = readProperty(tap_, kAudioTapPropertyFormat, asbd);
    if (status != noErr) return fail("tap format", status);
    const bool is_float = asbd.mFormatID == kAudioFormatLinearPCM &&
                          (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
                          asbd.mBitsPerChannel == 32;
    if (!is_float || asbd.mChannelsPerFrame < 1 || asbd.mChannelsPerFrame > 2) {
      return fail("tap format (expected float32, 1-2 channels)", kAudioDeviceUnsupportedFormatError);
    }
    format_.sample_rate = asbd.mSampleRate;
    format_.channels = asbd.mChannelsPerFrame;
    format_.interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
    tap_buffers_ = format_.interleaved ? 1 : format_.channels;
    bytes_per_frame_ = format_.interleaved ? kFloatBytes * format_.channels : kFloatBytes;

    // Private aggregate device: the output device (clock) plus the tap. Its input buffer list
    // holds the sub-device's input streams (if any) first and the tap's buffers last.
    NSString* aggregate_uid =
        [NSString stringWithFormat:@"%s.tap.%@", NMR_APP_BUNDLE_ID, [NSUUID UUID].UUIDString];
    NSDictionary* composition = @{
      @kAudioAggregateDeviceNameKey : @NMR_PRODUCT_NAME " capture",
      @kAudioAggregateDeviceUIDKey : aggregate_uid,
      @kAudioAggregateDeviceMainSubDeviceKey : output_uid,
      @kAudioAggregateDeviceIsPrivateKey : @YES,
      @kAudioAggregateDeviceIsStackedKey : @NO,
      @kAudioAggregateDeviceTapAutoStartKey : @YES,
      @kAudioAggregateDeviceSubDeviceListKey : @[ @{@kAudioSubDeviceUIDKey : output_uid} ],
      @kAudioAggregateDeviceTapListKey :
          @[ @{@kAudioSubTapDriftCompensationKey : @YES, @kAudioSubTapUIDKey : tap_uid} ],
    };
    status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &aggregate_);
    if (status != noErr) return fail("AudioHardwareCreateAggregateDevice", status);

    AudioDeviceIOProcID proc = nullptr;
    status = AudioDeviceCreateIOProcID(aggregate_, &SystemTap::ioProc, this, &proc);
    if (status != noErr || proc == nullptr) return fail("AudioDeviceCreateIOProcID", status);
    proc_ = proc;

    status = AudioDeviceStart(aggregate_, proc_);
    if (status != noErr) return fail("AudioDeviceStart", status);
  }
  return noErr;
}

void SystemTap::stop() noexcept {
  if (aggregate_ != kAudioObjectUnknown) {
    if (proc_ != nullptr) {
      AudioDeviceStop(aggregate_, proc_);
      // After this returns the HAL never calls ioProc again, so `this` may go away.
      AudioDeviceDestroyIOProcID(aggregate_, proc_);
      proc_ = nullptr;
    }
    AudioHardwareDestroyAggregateDevice(aggregate_);
    aggregate_ = kAudioObjectUnknown;
  }
  if (tap_ != kAudioObjectUnknown) {
    AudioHardwareDestroyProcessTap(tap_);
    tap_ = kAudioObjectUnknown;
  }
}

// HAL real-time IO thread. Copies only: no allocation, locks, ObjC or system calls.
OSStatus SystemTap::ioProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* input,
                           const AudioTimeStamp*, AudioBufferList* output, const AudioTimeStamp*,
                           void* client) noexcept {
  auto* self = static_cast<SystemTap*>(client);
  self->io_cycles_.fetch_add(1, std::memory_order_relaxed);
  // The aggregate includes the output device's streams; contribute silence to them.
  if (output != nullptr) {
    for (UInt32 i = 0; i < output->mNumberBuffers; ++i) {
      AudioBuffer& buffer = output->mBuffers[i];
      if (buffer.mData != nullptr) std::memset(buffer.mData, 0, buffer.mDataByteSize);
    }
  }
  self->capture(input);
  return noErr;
}

void SystemTap::capture(const AudioBufferList* input) noexcept {
  if (input == nullptr || tap_buffers_ == 0 || input->mNumberBuffers < tap_buffers_) {
    skipped_cycles_.fetch_add(1, std::memory_order_relaxed);
    return;
  }
  const AudioBuffer* tap = &input->mBuffers[input->mNumberBuffers - tap_buffers_];
  const uint32_t frames = tap[0].mDataByteSize / bytes_per_frame_;
  bool layout_ok = frames > 0;
  for (uint32_t i = 0; i < tap_buffers_; ++i) {
    const uint32_t expected_channels = format_.interleaved ? format_.channels : 1;
    layout_ok = layout_ok && tap[i].mData != nullptr &&
                tap[i].mNumberChannels == expected_channels &&
                tap[i].mDataByteSize / bytes_per_frame_ == frames;
  }
  if (!layout_ok) {
    skipped_cycles_.fetch_add(1, std::memory_order_relaxed);
    return;
  }

  const auto* first = static_cast<const float*>(tap[0].mData);
  if (format_.channels == 1) {
    ring_.writeSplit(first, first, frames);  // mono: L = R
  } else if (format_.interleaved) {
    ring_.write(first, frames);
  } else {
    ring_.writeSplit(first, static_cast<const float*>(tap[1].mData), frames);
  }
  frames_captured_.fetch_add(frames, std::memory_order_relaxed);
}

}  // namespace nmr
