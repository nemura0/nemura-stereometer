#include <nmr/dsp.h>
#include <nmr/test_mix.h>

#include <doctest/doctest.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace {

std::vector<float> mix(double rate, uint32_t frames, uint32_t chunk) {
  nmr::TestMix generator(rate);
  std::vector<float> out(size_t{frames} * 2);
  for (uint32_t at = 0; at < frames; at += chunk) {
    generator.fill(out.data() + size_t{at} * 2, std::min(chunk, frames - at));
  }
  return out;
}

}  // namespace

TEST_CASE("test mix: the same samples however it is read") {
  const std::vector<float> whole = mix(48000, 48000, 48000);
  CHECK(whole == mix(48000, 48000, 512));
  CHECK(whole == mix(48000, 48000, 1));
}

TEST_CASE("test mix: music-like levels, correlated, then in antiphase at 7 s") {
  nmr::TestMix generator(48000);
  std::vector<float> second(96000);
  double peak = 0;
  for (int s = 0; s < 8; ++s) {
    generator.fill(second.data(), 48000);
    double lr = 0, ll = 0, rr = 0;
    for (size_t i = 0; i < 48000; ++i) {
      const double l = second[2 * i], r = second[2 * i + 1];
      peak = std::max({peak, std::abs(l), std::abs(r)});
      lr += l * r;
      ll += l * l;
      rr += r * r;
    }
    const double correlation = lr / std::sqrt(ll * rr);
    if (s < 7) {
      CHECK(correlation > 0.5);
    } else {
      CHECK(correlation < -0.5);
    }
  }
  CHECK(peak > 0.5);
  CHECK(peak < 1.0);
}

TEST_CASE("test mix: skip moves on as if the frames were read") {
  nmr::TestMix read(44100);
  nmr::TestMix skipped(44100);
  std::vector<float> scratch(2 * 30000);
  read.fill(scratch.data(), 30000);
  skipped.skip(30000);
  std::vector<float> a(200), b(200);
  read.fill(a.data(), 100);
  skipped.fill(b.data(), 100);
  CHECK(a == b);
}

// The test WAVs and every baseline measured with them come from these samples: a change to the
// mix (even rounding) must be deliberate. The hash is of the float bit patterns, the same on
// arm64 and x86_64.
TEST_CASE("test mix: the samples are the ones the test WAVs were made from") {
  const std::vector<float> samples = mix(48000, 20 * 48000, 4096);
  uint64_t hash = 0xcbf29ce484222325ull;  // FNV-1a
  for (const float sample : samples) {
    uint32_t bits = 0;
    std::memcpy(&bits, &sample, sizeof bits);
    for (int byte = 0; byte < 4; ++byte) {
      hash ^= (bits >> (8 * byte)) & 0xFF;
      hash *= 0x100000001b3ull;
    }
  }
  CHECK(hash == 0x3def96dd0918e02cull);
}
