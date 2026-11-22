#include <nmr/system_tap.h>

#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>
#include <nmr/product_config.h>

#include <algorithm>
#include <cstddef>
#include <cstring>
#include <vector>

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

uint32_t inputStreamCount(AudioObjectID device) {
  const AudioObjectPropertyAddress address{kAudioDevicePropertyStreams,
                                           kAudioObjectPropertyScopeInput,
                                           kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr) return 0;
  return size / sizeof(AudioStreamID);
}

}  // namespace

OSStatus turnOffInputStreams(AudioObjectID device, AudioDeviceIOProcID proc,
                             uint32_t count) noexcept {
  if (proc == nullptr) return kAudioHardwareBadObjectError;
  if (count == 0) return noErr;
  const AudioObjectPropertyAddress address{kAudioDevicePropertyIOProcStreamUsage,
                                           kAudioObjectPropertyScopeInput,
                                           kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  OSStatus status = AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size);
  if (status != noErr) return status;
  constexpr size_t kHeader = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn);
  if (size < kHeader) return kAudioHardwareBadPropertySizeError;
  // uint64_t storage: aligned for the struct's leading pointer.
  std::vector<uint64_t> storage((size + sizeof(uint64_t) - 1) / sizeof(uint64_t), 0);
  auto* usage = reinterpret_cast<AudioHardwareIOProcStreamUsage*>(storage.data());
  usage->mIOProc = reinterpret_cast<void*>(proc);
  status = AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, usage);
  if (status != noErr) return status;
  const size_t fits = size < kHeader ? 0 : (size - kHeader) / sizeof(UInt32);
  if (usage->mNumberStreams < count || fits < usage->mNumberStreams) {
    return kAudioHardwareBadStreamError;
  }
  for (uint32_t i = 0; i < count; ++i) usage->mStreamIsOn[i] = 0;
  const auto used = static_cast<UInt32>(kHeader + sizeof(UInt32) * usage->mNumberStreams);
  return AudioObjectSetPropertyData(device, &address, 0, nullptr, used, usage);
}

namespace {

// Process facts from the HAL, for anyProcessPlays.
struct HalProcessFacts {
  bool runsOutput(AudioObjectID process) const noexcept {
    UInt32 running = 0;
    return readProperty(process, kAudioProcessPropertyIsRunningOutput, running) == noErr &&
           running != 0;
  }
  bool pid(AudioObjectID process, pid_t& out) const noexcept {
    return readProperty(process, kAudioProcessPropertyPID, out) == noErr;
  }
  bool playsOn(AudioObjectID process, AudioObjectID device) const noexcept {
    if (device == kAudioObjectUnknown) return false;
    const AudioObjectPropertyAddress address{kAudioProcessPropertyDevices,
                                             kAudioObjectPropertyScopeOutput,
                                             kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(process, &address, 0, nullptr, &size) != noErr) {
      return false;
    }
    std::vector<AudioObjectID> devices;
    try {
      devices.resize(size / sizeof(AudioObjectID));
    } catch (...) {
      return false;
    }
    if (devices.empty() ||
        AudioObjectGetPropertyData(process, &address, 0, nullptr, &size, devices.data()) !=
            noErr) {
      return false;
    }
    const size_t listed = std::min<size_t>(devices.size(), size / sizeof(AudioObjectID));
    for (size_t i = 0; i < listed; ++i) {
      if (devices[i] == device) return true;
    }
    return false;
  }
};

}  // namespace

bool processesPlayOutput(pid_t except, AudioObjectID device) noexcept {
  const AudioObjectPropertyAddress address{kAudioHardwarePropertyProcessObjectList,
                                           kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &size) !=
      noErr) {
    return false;
  }
  std::vector<AudioObjectID> processes;
  try {
    processes.resize(size / sizeof(AudioObjectID));
  } catch (...) {
    return false;
  }
  if (processes.empty() ||
      AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size,
                                 processes.data()) != noErr) {
    return false;
  }
  // The list may have shrunk meanwhile.
  const size_t listed = std::min<size_t>(processes.size(), size / sizeof(AudioObjectID));
  return anyProcessPlays(processes.data(), listed, except, device, HalProcessFacts{});
}

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
    output_ = output;

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
      return fail("tap format (expected float32, 1-2 channels)",
                  kAudioDeviceUnsupportedFormatError);
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

    // Only the tap's stream: the output device's own inputs (if any) stay off.
    status = turnOffInputStreams(aggregate_, proc_, inputStreamCount(output));
    if (status != noErr) return fail("IO proc stream usage", status);

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
  output_ = kAudioObjectUnknown;
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
