// The capture IO proc must not read the clock device's own inputs (a loopback driver such as
// VB-Cable, or an interface with inputs), or macOS shows the app as using the microphone.
// Needs a device with input and output streams; skipped where there is none (CI).
#include <doctest/doctest.h>

#import <CoreAudio/AudioHardware.h>
#import <Foundation/Foundation.h>
#include <nmr/system_tap.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <thread>
#include <vector>

#include <unistd.h>

namespace {

uint32_t streamCount(AudioObjectID device, AudioObjectPropertyScope scope) {
  const AudioObjectPropertyAddress address{kAudioDevicePropertyStreams, scope,
                                           kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr) return 0;
  return size / sizeof(AudioStreamID);
}

AudioObjectID duplexDevice() {
  const AudioObjectPropertyAddress address{kAudioHardwarePropertyDevices,
                                           kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &size) !=
      noErr) {
    return kAudioObjectUnknown;
  }
  std::vector<AudioObjectID> devices(size / sizeof(AudioObjectID));
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size,
                                 devices.data()) != noErr) {
    return kAudioObjectUnknown;
  }
  for (AudioObjectID device : devices) {
    if (streamCount(device, kAudioObjectPropertyScopeInput) > 0 &&
        streamCount(device, kAudioObjectPropertyScopeOutput) > 0) {
      return device;
    }
  }
  return kAudioObjectUnknown;
}

NSString* deviceUID(AudioObjectID device) {
  const AudioObjectPropertyAddress address{kAudioDevicePropertyDeviceUID,
                                           kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
  CFStringRef uid = nullptr;
  UInt32 size = sizeof(uid);
  if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &uid) != noErr) return nil;
  return (__bridge_transfer NSString*)uid;
}

// The HAL still hands a turned-off stream a scratch buffer, so the test asks the HAL whether
// this process runs input IO (what the microphone indicator follows).
bool processRunsInput() {
  pid_t pid = getpid();
  AudioObjectID process = kAudioObjectUnknown;
  UInt32 size = sizeof(process);
  const AudioObjectPropertyAddress translate{kAudioHardwarePropertyTranslatePIDToProcessObject,
                                             kAudioObjectPropertyScopeGlobal,
                                             kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &translate, sizeof(pid), &pid, &size,
                                 &process) != noErr) {
    return true;
  }
  UInt32 running = 1;
  size = sizeof(running);
  const AudioObjectPropertyAddress address{kAudioProcessPropertyIsRunningInput,
                                           kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(process, &address, 0, nullptr, &size, &running) != noErr) {
    return true;
  }
  return running != 0;
}

OSStatus observe(AudioObjectID, const AudioTimeStamp*, const AudioBufferList*,
                 const AudioTimeStamp*, AudioBufferList* output, const AudioTimeStamp*,
                 void* client) {
  static_cast<std::atomic<uint64_t>*>(client)->fetch_add(1, std::memory_order_relaxed);
  for (UInt32 i = 0; output != nullptr && i < output->mNumberBuffers; ++i) {
    if (output->mBuffers[i].mData != nullptr) {
      memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    }
  }
  return noErr;
}

std::vector<UInt32> streamUsage(AudioObjectID device, AudioDeviceIOProcID proc) {
  const AudioObjectPropertyAddress address{kAudioDevicePropertyIOProcStreamUsage,
                                           kAudioObjectPropertyScopeInput,
                                           kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr) return {};
  std::vector<uint64_t> storage((size + sizeof(uint64_t) - 1) / sizeof(uint64_t));
  auto* usage = reinterpret_cast<AudioHardwareIOProcStreamUsage*>(storage.data());
  usage->mIOProc = reinterpret_cast<void*>(proc);
  if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, usage) != noErr) return {};
  return {usage->mStreamIsOn, usage->mStreamIsOn + usage->mNumberStreams};
}

}  // namespace

TEST_CASE("the IO proc can be kept off the clock device's inputs") {
  const AudioObjectID device = duplexDevice();
  NSString* uid = device == kAudioObjectUnknown ? nil : deviceUID(device);
  if (uid == nil) {
    MESSAGE("skipped: no audio device with both inputs and outputs");
    return;
  }
  NSDictionary* composition = @{
    @kAudioAggregateDeviceNameKey : @"nmr stream usage test",
    @kAudioAggregateDeviceUIDKey :
        [@"nmr.test.streams." stringByAppendingString:NSUUID.UUID.UUIDString],
    @kAudioAggregateDeviceMainSubDeviceKey : uid,
    @kAudioAggregateDeviceIsPrivateKey : @YES,
    @kAudioAggregateDeviceSubDeviceListKey : @[ @{@kAudioSubDeviceUIDKey : uid} ],
  };
  AudioObjectID aggregate = kAudioObjectUnknown;
  REQUIRE(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &aggregate) ==
          noErr);
  std::atomic<uint64_t> cycles{0};
  AudioDeviceIOProcID proc = nullptr;
  REQUIRE(AudioDeviceCreateIOProcID(aggregate, observe, &cycles, &proc) == noErr);

  const uint32_t inputs = streamCount(device, kAudioObjectPropertyScopeInput);
  CHECK(nmr::turnOffInputStreams(aggregate, proc, inputs) == noErr);
  const std::vector<UInt32> usage = streamUsage(aggregate, proc);
  REQUIRE(usage.size() >= inputs);
  for (uint32_t i = 0; i < inputs; ++i) CHECK(usage[i] == 0);

  REQUIRE(AudioDeviceStart(aggregate, proc) == noErr);
  for (int i = 0; i < 100 && cycles.load() < 5; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  const bool runs_input = processRunsInput();
  AudioDeviceStop(aggregate, proc);
  AudioDeviceDestroyIOProcID(aggregate, proc);
  AudioHardwareDestroyAggregateDevice(aggregate);

  CHECK(cycles.load() >= 5);
  CHECK_FALSE(runs_input);
}

TEST_CASE("turning off input streams rejects a missing IO proc") {
  CHECK(nmr::turnOffInputStreams(kAudioObjectUnknown, nullptr, 1) != noErr);
}
