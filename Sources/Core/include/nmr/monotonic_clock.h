// CLOCK_UPTIME_RAW in nanoseconds, the same value in native and Rosetta processes.
//
// Raw mach ticks are not comparable across architectures: arm64 code sees 24 MHz ticks
// (timebase 125/3) while Rosetta reports nanoseconds to x86_64 code (timebase 1/1). Shared
// timestamps (shm heartbeats) therefore use this clock.
#pragma once

#include <mach/mach_time.h>

#include <cstdint>

namespace nmr {

class MonotonicClock {
 public:
  // Reads the timebase; construct off the audio thread.
  MonotonicClock() noexcept {
    mach_timebase_info_data_t timebase{};
    if (mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.numer != 0 &&
        timebase.denom != 0) {
      numer_ = timebase.numer;
      denom_ = timebase.denom;
    }
  }

  // Real-time safe: a commpage read and integer math (overflows after about 190 years of uptime).
  [[nodiscard]] uint64_t nowNs() const noexcept { return mach_absolute_time() * numer_ / denom_; }

 private:
  uint32_t numer_ = 1;
  uint32_t denom_ = 1;
};

}  // namespace nmr
