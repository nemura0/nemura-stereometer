// WAV decoding for --feed and the snapshot tool: PCM 16/24/32, float 32/64, mono to stereo.
#include <doctest/doctest.h>
#include <nmr/wav_file.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace wav = nmr::wav;

namespace {

void put16(std::vector<uint8_t>& out, uint32_t v) {
  out.push_back(v & 0xFF);
  out.push_back((v >> 8) & 0xFF);
}
void put32(std::vector<uint8_t>& out, uint32_t v) {
  put16(out, v & 0xFFFF);
  put16(out, v >> 16);
}
void tag(std::vector<uint8_t>& out, const char* text) { out.insert(out.end(), text, text + 4); }

// A WAV file: format `format` (1 PCM, 3 float, 0xFFFE extensible with `sub` as its subformat).
std::vector<uint8_t> file(uint16_t format, uint16_t channels, uint32_t rate, uint16_t bits,
                          const std::vector<uint8_t>& data, uint16_t sub = 0,
                          bool odd_chunk_first = false) {
  std::vector<uint8_t> body;
  tag(body, "WAVE");
  if (odd_chunk_first) {  // an odd-sized chunk before fmt: padded to an even size
    tag(body, "LIST");
    put32(body, 3);
    body.insert(body.end(), {1, 2, 3, 0});
  }
  tag(body, "fmt ");
  const bool extensible = format == 0xFFFE;
  put32(body, extensible ? 40 : 16);
  put16(body, format);
  put16(body, channels);
  put32(body, rate);
  put32(body, rate * channels * bits / 8);
  put16(body, channels * bits / 8);
  put16(body, bits);
  if (extensible) {
    put16(body, 22);
    put16(body, bits);
    put32(body, 0);
    put16(body, sub);
    body.insert(body.end(), {0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00,
                             0x38, 0x9B, 0x71});
  }
  tag(body, "data");
  put32(body, static_cast<uint32_t>(data.size()));
  body.insert(body.end(), data.begin(), data.end());
  std::vector<uint8_t> out;
  tag(out, "RIFF");
  put32(out, static_cast<uint32_t>(body.size()));
  out.insert(out.end(), body.begin(), body.end());
  return out;
}

std::vector<uint8_t> floats(const std::vector<float>& values) {
  std::vector<uint8_t> out(values.size() * 4);
  std::memcpy(out.data(), values.data(), out.size());
  return out;
}

wav::Audio decoded(const std::vector<uint8_t>& bytes) {
  wav::Error error = wav::Error::kUnreadable;
  auto audio = wav::decode(bytes.data(), bytes.size(), error);
  REQUIRE(audio.has_value());
  CHECK(error == wav::Error::kNone);
  return *audio;
}

}  // namespace

TEST_CASE("wav: 32-bit float stereo is read as it is") {
  const std::vector<float> samples = {0.5f, -0.25f, 1.0f, -1.0f};
  const wav::Audio audio = decoded(file(3, 2, 48000, 32, floats(samples)));
  CHECK(audio.sample_rate == 48000);
  CHECK(audio.frames() == 2);
  CHECK(audio.stereo == samples);
}

TEST_CASE("wav: 16-bit mono becomes both channels") {
  std::vector<uint8_t> data;
  put16(data, 0x4000);  // 0.5
  put16(data, 0x8000);  // -1
  const wav::Audio audio = decoded(file(1, 1, 44100, 16, data));
  CHECK(audio.sample_rate == 44100);
  CHECK(audio.stereo == std::vector<float>{0.5f, 0.5f, -1.0f, -1.0f});
}

TEST_CASE("wav: 24-bit and 32-bit PCM, float64, extensible") {
  const std::vector<uint8_t> pcm24 = {0x00, 0x00, 0x40, 0x00, 0x00, 0xC0};  // 0.5, -0.5
  CHECK(decoded(file(1, 2, 96000, 24, pcm24)).stereo == std::vector<float>{0.5f, -0.5f});
  std::vector<uint8_t> pcm32;
  put32(pcm32, 0x40000000);
  put32(pcm32, 0xC0000000);
  CHECK(decoded(file(1, 2, 48000, 32, pcm32)).stereo == std::vector<float>{0.5f, -0.5f});
  std::vector<uint8_t> f64(16);
  const double values[] = {0.25, -0.75};
  std::memcpy(f64.data(), values, 16);
  CHECK(decoded(file(3, 2, 48000, 64, f64)).stereo == std::vector<float>{0.25f, -0.75f});
  CHECK(decoded(file(0xFFFE, 2, 48000, 32, floats({0.1f, 0.2f}), 3)).stereo ==
        std::vector<float>{0.1f, 0.2f});
  CHECK(decoded(file(1, 2, 48000, 16, {0, 0x40, 0, 0xC0}, 0, true)).stereo ==
        std::vector<float>{0.5f, -0.5f});
}

TEST_CASE("wav: more channels give the first two; a cut-off frame is dropped") {
  const std::vector<float> quad = {0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f, 0.7f, 0.8f, 0.9f};
  const wav::Audio audio = decoded(file(3, 4, 48000, 32, floats(quad)));
  CHECK(audio.stereo == std::vector<float>{0.1f, 0.2f, 0.5f, 0.6f});
}

TEST_CASE("wav: files it cannot play say why") {
  wav::Error error = wav::Error::kNone;
  const std::string text = "not a wav file at all";
  CHECK_FALSE(wav::decode(reinterpret_cast<const uint8_t*>(text.data()), text.size(), error));
  CHECK(error == wav::Error::kNotWav);
  const std::vector<uint8_t> eight_bit = file(1, 2, 48000, 8, {0x80, 0x80});
  CHECK_FALSE(wav::decode(eight_bit.data(), eight_bit.size(), error));
  CHECK(error == wav::Error::kUnsupported);
  const std::vector<uint8_t> no_rate = file(3, 2, 0, 32, floats({0.1f, 0.2f}));
  CHECK_FALSE(wav::decode(no_rate.data(), no_rate.size(), error));
  CHECK(error == wav::Error::kUnsupported);
  const std::vector<uint8_t> empty = file(3, 2, 48000, 32, {});
  CHECK_FALSE(wav::decode(empty.data(), empty.size(), error));
  CHECK(error == wav::Error::kEmpty);
  CHECK_FALSE(wav::read("/nonexistent/nowhere.wav", error));
  CHECK(error == wav::Error::kUnreadable);
}

TEST_CASE("wav: audio past the cap is refused as too long, not decoded") {
  wav::Error error = wav::Error::kNone;
  const std::vector<uint8_t> three = file(3, 2, 48000, 32, floats({0.1f, 0.2f, 0.3f, 0.4f, 0.5f,
                                                                   0.6f}));
  CHECK_FALSE(wav::decode(three.data(), three.size(), error, 2));
  CHECK(error == wav::Error::kTooLong);
  CHECK(wav::decode(three.data(), three.size(), error, 3));
  CHECK(wav::kMaxFrames * 2 * sizeof(float) <= size_t{1} << 30);  // at most 1 GiB decoded
}

TEST_CASE("wav: every cut-off prefix of a file decodes what it holds or says why") {
  const std::vector<float> samples = {0.1f, -0.1f, 0.2f, -0.2f, 0.3f, -0.3f};
  const std::vector<uint8_t> whole = file(0xFFFE, 2, 48000, 32, floats(samples), 3, true);
  for (size_t size = 0; size <= whole.size(); ++size) {
    const std::vector<uint8_t> prefix(whole.begin(), whole.begin() + static_cast<long>(size));
    wav::Error error = wav::Error::kNone;
    const auto audio = wav::decode(prefix.data(), prefix.size(), error);
    if (!audio) {
      CHECK(error != wav::Error::kNone);
      continue;
    }
    REQUIRE(audio->frames() <= 3);
    for (size_t i = 0; i < audio->stereo.size(); ++i) CHECK(audio->stereo[i] == samples[i]);
  }
}

TEST_CASE("wav: an extensible header is read only with its whole subformat GUID") {
  wav::Error error = wav::Error::kNone;
  // fmt of 26 bytes, cbSize 0: the bytes where the GUID would be are not one.
  std::vector<uint8_t> body;
  tag(body, "WAVE");
  tag(body, "fmt ");
  put32(body, 26);
  put16(body, 0xFFFE);
  put16(body, 2);
  put32(body, 48000);
  put32(body, 48000 * 8);
  put16(body, 8);
  put16(body, 32);
  put16(body, 0);  // cbSize
  put16(body, 0);
  put16(body, 0);
  put16(body, 0);
  put16(body, 3);  // where the subformat's first word would sit
  tag(body, "data");
  put32(body, 8);
  const std::vector<uint8_t> data = floats({0.1f, 0.2f});
  body.insert(body.end(), data.begin(), data.end());
  std::vector<uint8_t> short_fmt;
  tag(short_fmt, "RIFF");
  put32(short_fmt, static_cast<uint32_t>(body.size()));
  short_fmt.insert(short_fmt.end(), body.begin(), body.end());
  CHECK_FALSE(wav::decode(short_fmt.data(), short_fmt.size(), error));
  CHECK(error == wav::Error::kUnsupported);

  std::vector<uint8_t> other_guid = file(0xFFFE, 2, 48000, 32, floats({0.1f, 0.2f}), 3);
  other_guid[12 + 47] ^= 0xFF;  // the GUID's last byte (the fmt chunk starts at 12)
  CHECK_FALSE(wav::decode(other_guid.data(), other_guid.size(), error));
  CHECK(error == wav::Error::kUnsupported);
}

TEST_CASE("wav: 24-bit extremes, a short fmt, and float64 beyond float's range") {
  const std::vector<uint8_t> pcm24 = {0x00, 0x00, 0x80, 0xFF, 0xFF, 0xFF};  // -1, -1/2^23
  CHECK(decoded(file(1, 2, 48000, 24, pcm24)).stereo ==
        std::vector<float>{-1.0f, -1.0f / 8388608.0f});
  std::vector<uint8_t> f64(16);
  const double values[] = {1e300, -1e300};
  std::memcpy(f64.data(), values, 16);
  for (const float value : decoded(file(3, 2, 48000, 64, f64)).stereo) {
    CHECK(std::isfinite(value));
  }
  std::vector<uint8_t> bytes = file(3, 2, 48000, 32, floats({0.1f, 0.2f}));
  bytes[12 + 4] = 14;  // a fmt chunk too short to hold a format
  wav::Error error = wav::Error::kNone;
  CHECK_FALSE(wav::decode(bytes.data(), bytes.size(), error));
  CHECK(error == wav::Error::kUnsupported);
}

TEST_CASE("wav: read decodes a file on disk, and an empty file says it is not a WAV") {
  const auto dir = std::filesystem::temp_directory_path();
  const std::string path = (dir / "nmr_wav_read_test.wav").string();
  const std::vector<uint8_t> bytes = file(3, 2, 44100, 32, floats({0.25f, -0.5f, 1.0f, 0.0f}));
  {
    std::ofstream out(path, std::ios::binary);
    out.write(reinterpret_cast<const char*>(bytes.data()),
              static_cast<std::streamsize>(bytes.size()));
  }
  wav::Error error = wav::Error::kUnreadable;
  const auto audio = wav::read(path, error);
  REQUIRE(audio);
  CHECK(error == wav::Error::kNone);
  CHECK(audio->sample_rate == 44100);
  CHECK(audio->stereo == std::vector<float>{0.25f, -0.5f, 1.0f, 0.0f});
  { std::ofstream truncate(path, std::ios::binary | std::ios::trunc); }
  CHECK_FALSE(wav::read(path, error));
  CHECK(error == wav::Error::kNotWav);
  std::remove(path.c_str());
}
