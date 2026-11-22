// The capture tells "nothing plays" from "something plays but only zeros arrive" (a denied
// audio-capture grant) by asking the HAL which processes run output on the tapped device. The
// decision is checked over fake process facts; the HAL query, by this test process playing
// silence through the default output (skipped where there is no output device: CI).
#include <doctest/doctest.h>

#import <CoreAudio/AudioHardware.h>
#include <nmr/system_tap.h>

#include <chrono>
#include <cstring>
#include <map>
#include <set>
#include <thread>
#include <vector>

#include <unistd.h>

namespace {

OSStatus writeSilence(AudioObjectID, const AudioTimeStamp*, const AudioBufferList*,
                      const AudioTimeStamp*, AudioBufferList* output, const AudioTimeStamp*,
                      void*) {
  for (UInt32 i = 0; i < output->mNumberBuffers; ++i) {
    if (output->mBuffers[i].mData != nullptr) {
      std::memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    }
  }
  return noErr;
}

AudioObjectID defaultOutput() {
  const AudioObjectPropertyAddress address{kAudioHardwarePropertyDefaultOutputDevice,
                                           kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
  AudioObjectID device = kAudioObjectUnknown;
  UInt32 size = sizeof(device);
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size,
                                 &device) != noErr) {
    return kAudioObjectUnknown;
  }
  return device;
}

struct FakeProcess {
  bool running = false;
  pid_t pid = 0;
  std::set<AudioObjectID> devices;
  bool readable = true;  // false: the HAL cannot answer for it
};

// Process facts as the HAL would give them, counting the reads.
struct FakeFacts {
  std::map<AudioObjectID, FakeProcess> processes;
  mutable int reads = 0;

  bool runsOutput(AudioObjectID process) const {
    ++reads;
    const auto& facts = processes.at(process);
    return facts.readable && facts.running;
  }
  bool pid(AudioObjectID process, pid_t& out) const {
    ++reads;
    const auto& facts = processes.at(process);
    out = facts.pid;
    return facts.readable;
  }
  bool playsOn(AudioObjectID process, AudioObjectID device) const {
    ++reads;
    const auto& facts = processes.at(process);
    return facts.readable && facts.devices.count(device) > 0;
  }
};

bool plays(const FakeFacts& facts, pid_t except, AudioObjectID device) {
  std::vector<AudioObjectID> ids;
  for (const auto& entry : facts.processes) ids.push_back(entry.first);
  return nmr::anyProcessPlays(ids.data(), ids.size(), except, device, facts);
}

constexpr AudioObjectID kSpeakers = 70;
constexpr AudioObjectID kInterface = 80;

}  // namespace

TEST_CASE("process output: a process playing on the tapped device counts") {
  FakeFacts facts;
  facts.processes[1] = {.running = true, .pid = 100, .devices = {kSpeakers}};
  CHECK(plays(facts, -1, kSpeakers));
  CHECK(plays(facts, 200, kSpeakers));
}

TEST_CASE("process output: the process left out, other devices and idle processes do not") {
  FakeFacts facts;
  facts.processes[1] = {.running = true, .pid = 100, .devices = {kSpeakers}};  // left out
  facts.processes[2] = {.running = true, .pid = 101, .devices = {kInterface}};  // elsewhere
  facts.processes[3] = {.running = false, .pid = 102, .devices = {kSpeakers}};  // idle
  facts.processes[4] = {.running = true, .pid = 103, .devices = {kSpeakers}, .readable = false};
  CHECK_FALSE(plays(facts, 100, kSpeakers));
  CHECK(plays(facts, -1, kSpeakers));  // nothing left out: process 1 counts
  CHECK(plays(facts, 100, kInterface));
  CHECK_FALSE(plays(facts, 100, kAudioObjectUnknown));
}

TEST_CASE("process output: idle processes cost one read each") {
  FakeFacts facts;
  for (AudioObjectID id = 1; id <= 10; ++id) facts.processes[id] = {.running = false};
  CHECK_FALSE(plays(facts, 100, kSpeakers));
  CHECK(facts.reads == 10);
}

TEST_CASE("process output: a process that plays counts, unless it is the one left out") {
  const AudioObjectID device = defaultOutput();
  AudioDeviceIOProcID proc = nullptr;
  if (device == kAudioObjectUnknown ||
      AudioDeviceCreateIOProcID(device, writeSilence, nullptr, &proc) != noErr) {
    MESSAGE("skipped: no default output device");
    return;
  }
  REQUIRE(AudioDeviceStart(device, proc) == noErr);
  // The HAL marks the process as running output once IO has started; allow it a moment.
  bool seen = false;
  for (int i = 0; i < 40 && !seen; ++i) {
    seen = nmr::processesPlayOutput(-1, device);
    if (!seen) std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  CHECK(seen);
  // No process plays on a device that does not exist.
  CHECK_FALSE(nmr::processesPlayOutput(-1, kAudioObjectUnknown));
  // Leaving this process out: whatever else plays decides, but asking must work.
  (void)nmr::processesPlayOutput(getpid(), device);
  AudioDeviceStop(device, proc);
  AudioDeviceDestroyIOProcID(device, proc);
}
