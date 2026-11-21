// Out-of-process Audio Unit smoke test.
//
// Instantiates the installed NEMURA Stereometer AU with kAudioComponentInstantiation_LoadOutOfProcess,
// checks that the component's binary was not mapped into this process, renders one second of a
// test signal (random full-scale values, denormals, signed zeros) through it in varying block
// sizes, and requires the output to be bit-identical to the input (null test).
//
//   nmr_au_oop_host [--in-process]     exit code 0 = pass
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <nmr/product_config.h>

#include <atomic>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr double kSampleRate = 48000.0;
constexpr UInt32 kChannels = 2;
constexpr UInt32 kMaxFrames = 1024;
constexpr UInt32 kTotalFrames = 48000;
constexpr UInt32 kBlockSizes[] = {64, 128, 17, 512, 480, 1024, 1};
constexpr double kInstantiateTimeoutSeconds = 30.0;

// Deterministic test signal: every channel gets its own sequence. A few special values are
// mixed in because a pass-through must not flush denormals or normalize signed zeros.
float testSample(UInt32 channel, UInt64 frame) {
  switch ((frame + channel * 7) % 97) {
    case 0: return 1.0e-40f;  // denormal
    case 1: return -1.0e-42f;
    case 2: return -0.0f;
    case 3: return 0.0f;
    case 4: return 1.0f;
    case 5: return -1.0f;
    default: break;
  }
  UInt64 x = (frame + 1) * 0x9E3779B97F4A7C15ull ^ (UInt64{channel} + 1) * 0xD1B54A32D192ED03ull;
  x ^= x >> 31;
  x *= 0xBF58476D1CE4E5B9ull;
  x ^= x >> 27;
  return static_cast<float>(static_cast<double>(x >> 40) / static_cast<double>(1ull << 23) - 1.0);
}

struct InputState {
  UInt64 next_frame = 0;
};

struct Instantiation {
  std::atomic<bool> done{false};
  AudioComponentInstance unit = nullptr;
  OSStatus status = noErr;
};

OSStatus provideInput(void* ref, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32,
                      UInt32 frames, AudioBufferList* io) {
  auto* state = static_cast<InputState*>(ref);
  for (UInt32 b = 0; b < io->mNumberBuffers; ++b) {
    auto* data = static_cast<float*>(io->mBuffers[b].mData);
    if (data == nullptr) continue;
    for (UInt32 i = 0; i < frames; ++i) data[i] = testSample(b, state->next_frame + i);
  }
  state->next_frame += frames;
  return noErr;
}

bool componentImageLoadedHere() {
  const std::string needle = std::string(NMR_PRODUCT_NAME) + ".component/";
  for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
    const char* name = _dyld_get_image_name(i);
    if (name != nullptr && std::strstr(name, needle.c_str()) != nullptr) return true;
  }
  return false;
}

bool setFormat(AudioUnit unit, AudioUnitScope scope) {
  AudioStreamBasicDescription format{};
  format.mSampleRate = kSampleRate;
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) |
                        static_cast<AudioFormatFlags>(kAudioFormatFlagIsNonInterleaved);
  format.mBytesPerPacket = sizeof(float);
  format.mFramesPerPacket = 1;
  format.mBytesPerFrame = sizeof(float);
  format.mChannelsPerFrame = kChannels;
  format.mBitsPerChannel = 32;
  return AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, &format,
                              sizeof(format)) == noErr;
}

int fail(const char* what, OSStatus status = noErr) {
  std::fprintf(stderr, "FAIL: %s (OSStatus %d)\n", what, static_cast<int>(status));
  return 1;
}

}  // namespace

int main(int argc, char** argv) {
  @autoreleasepool {
    const bool in_process = argc > 1 && std::strcmp(argv[1], "--in-process") == 0;
    AudioComponentDescription description{NMR_AU_TYPE_CODE, NMR_AU_SUBTYPE_CODE,
                                          NMR_AU_MANUFACTURER_CODE, 0, 0};
    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    if (component == nullptr) return fail("component not registered (run scripts/install-plugins.sh)");

    // Shared with the completion handler, which may still run after a timeout.
    const auto result = std::make_shared<Instantiation>();
    const AudioComponentInstantiationOptions options =
        in_process ? kAudioComponentInstantiation_LoadInProcess
                   : kAudioComponentInstantiation_LoadOutOfProcess;
    AudioComponentInstantiate(component, options, ^(AudioComponentInstance instance, OSStatus status) {
      result->unit = instance;
      result->status = status;
      result->done.store(true, std::memory_order_release);
    });
    // The completion may arrive on the main queue: keep the run loop turning while waiting.
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:kInstantiateTimeoutSeconds];
    while (!result->done.load(std::memory_order_acquire) && deadline.timeIntervalSinceNow > 0) {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
    if (!result->done.load(std::memory_order_acquire)) return fail("instantiation timed out");
    AudioComponentInstance unit = result->unit;
    if (result->status != noErr || unit == nullptr) {
      return fail("AudioComponentInstantiate", result->status);
    }

    const bool loaded_here = componentImageLoadedHere();
    std::printf("instantiated %s; component binary %s this process\n",
                in_process ? "in process" : "out of process",
                loaded_here ? "IS mapped into" : "is not mapped into");
    if (!in_process && loaded_here) return fail("out-of-process instance was loaded in process");

    if (!setFormat(unit, kAudioUnitScope_Input) || !setFormat(unit, kAudioUnitScope_Output)) {
      return fail("stream format");
    }
    UInt32 max_frames = kMaxFrames;
    OSStatus status = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                           kAudioUnitScope_Global, 0, &max_frames,
                                           sizeof(max_frames));
    if (status != noErr) return fail("MaximumFramesPerSlice", status);

    InputState input;
    AURenderCallbackStruct callback{provideInput, &input};
    status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    if (status != noErr) return fail("SetRenderCallback", status);

    status = AudioUnitInitialize(unit);
    if (status != noErr) return fail("AudioUnitInitialize", status);

    std::vector<float> out_left(kMaxFrames);
    std::vector<float> out_right(kMaxFrames);
    std::vector<UInt8> list_storage(offsetof(AudioBufferList, mBuffers) +
                                    sizeof(AudioBuffer) * kChannels);
    auto* output = reinterpret_cast<AudioBufferList*>(list_storage.data());

    UInt64 rendered = 0;
    UInt64 mismatches = 0;
    size_t block_index = 0;
    while (rendered < kTotalFrames) {
      UInt32 frames = kBlockSizes[block_index++ % (sizeof(kBlockSizes) / sizeof(kBlockSizes[0]))];
      if (rendered + frames > kTotalFrames) frames = static_cast<UInt32>(kTotalFrames - rendered);

      output->mNumberBuffers = kChannels;
      float* channels[kChannels] = {out_left.data(), out_right.data()};
      for (UInt32 c = 0; c < kChannels; ++c) {
        output->mBuffers[c].mNumberChannels = 1;
        output->mBuffers[c].mDataByteSize = frames * sizeof(float);
        output->mBuffers[c].mData = channels[c];
      }
      AudioTimeStamp timestamp{};
      timestamp.mSampleTime = static_cast<Float64>(rendered);
      timestamp.mFlags = kAudioTimeStampSampleTimeValid;
      AudioUnitRenderActionFlags flags = 0;
      status = AudioUnitRender(unit, &flags, &timestamp, 0, frames, output);
      if (status != noErr) return fail("AudioUnitRender", status);

      for (UInt32 c = 0; c < kChannels; ++c) {
        const auto* data = static_cast<const float*>(output->mBuffers[c].mData);
        for (UInt32 i = 0; i < frames; ++i) {
          const float expected = testSample(c, rendered + i);
          if (std::memcmp(&data[i], &expected, sizeof(float)) != 0) ++mismatches;
        }
      }
      rendered += frames;
    }

    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);

    std::printf("rendered %llu frames x %u channels: %llu mismatching samples\n",
                static_cast<unsigned long long>(rendered), kChannels,
                static_cast<unsigned long long>(mismatches));
    if (mismatches != 0) return fail("output is not bit-identical to the input");
    std::printf("PASS\n");
    return 0;
  }
}
