#include "nmr/wav_file.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstring>

namespace nmr::wav {

namespace {

constexpr uint16_t kPcm = 1;
constexpr uint16_t kFloat = 3;
constexpr uint16_t kExtensible = 0xFFFE;
// KSDATAFORMAT_SUBTYPE_*: the format code's two bytes, then this common tail.
constexpr uint8_t kGuidTail[14] = {0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80,
                                   0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71};
// Past this a float64 sample is no sound anyway; the cast to float stays defined.
constexpr double kMaxSample = 1e6;

uint32_t u32(const uint8_t* p) noexcept {
  return p[0] | p[1] << 8 | p[2] << 16 | uint32_t{p[3]} << 24;
}
uint16_t u16(const uint8_t* p) noexcept { return static_cast<uint16_t>(p[0] | p[1] << 8); }

struct Format {
  uint16_t code = 0;  // kPcm or kFloat
  uint16_t channels = 0;
  uint32_t rate = 0;
  uint16_t bits = 0;
};

bool supported(const Format& f) noexcept {
  const bool pcm = f.code == kPcm && (f.bits == 16 || f.bits == 24 || f.bits == 32);
  const bool floating = f.code == kFloat && (f.bits == 32 || f.bits == 64);
  return (pcm || floating) && f.channels > 0 && f.rate >= 8000 && f.rate <= 768000;
}

float sample(const uint8_t* p, const Format& f) noexcept {
  if (f.code == kFloat) {
    if (f.bits == 32) {
      float value = 0;
      std::memcpy(&value, p, 4);
      return value;
    }
    double value = 0;
    std::memcpy(&value, p, 8);
    return static_cast<float>(std::clamp(value, -kMaxSample, kMaxSample));  // NaN stays NaN
  }
  switch (f.bits) {
    case 16: return static_cast<float>(static_cast<int16_t>(u16(p))) / 32768.0f;
    case 24: {
      // Three bytes, placed high and shifted back down to sign-extend.
      const int32_t v = static_cast<int32_t>((uint32_t{p[0]} << 8) | (uint32_t{p[1]} << 16) |
                                             (uint32_t{p[2]} << 24)) >> 8;
      return static_cast<float>(v) / 8388608.0f;
    }
    default: return static_cast<float>(static_cast<double>(static_cast<int32_t>(u32(p))) /
                                       2147483648.0);
  }
}

}  // namespace

std::optional<Audio> decode(const uint8_t* bytes, size_t size, Error& error,
                           uint64_t max_frames) {
  if (bytes == nullptr || size < 12 || std::memcmp(bytes, "RIFF", 4) != 0 ||
      std::memcmp(bytes + 8, "WAVE", 4) != 0) {
    error = Error::kNotWav;
    return std::nullopt;
  }
  Format format;
  const uint8_t* data = nullptr;
  size_t data_size = 0;
  for (size_t at = 12; at + 8 <= size;) {
    const uint8_t* chunk = bytes + at;
    const size_t chunk_size = std::min<size_t>(u32(chunk + 4), size - at - 8);  // cut-off files
    if (std::memcmp(chunk, "fmt ", 4) == 0 && chunk_size >= 16) {
      format = {u16(chunk + 8), u16(chunk + 10), u32(chunk + 12), u16(chunk + 22)};
      if (format.code == kExtensible) {
        // cbSize 22 or more, then the valid bits, the channel mask and the subformat GUID.
        const bool whole = chunk_size >= 40 && u16(chunk + 24) >= 22 &&
                           std::memcmp(chunk + 34, kGuidTail, sizeof kGuidTail) == 0;
        format.code = whole ? u16(chunk + 32) : 0;
      }
    } else if (std::memcmp(chunk, "data", 4) == 0 && data == nullptr) {
      data = chunk + 8;
      data_size = chunk_size;
    }
    at += 8 + chunk_size + (chunk_size & 1);
  }
  if (!supported(format)) {
    error = Error::kUnsupported;
    return std::nullopt;
  }
  const size_t sample_bytes = format.bits / 8;
  const size_t frame_bytes = sample_bytes * format.channels;
  const size_t frames = data != nullptr ? data_size / frame_bytes : 0;
  if (frames == 0) {
    error = Error::kEmpty;
    return std::nullopt;
  }
  if (frames > max_frames) {
    error = Error::kTooLong;
    return std::nullopt;
  }
  Audio audio;
  audio.sample_rate = format.rate;
  audio.stereo.resize(frames * 2);
  const size_t right = format.channels > 1 ? sample_bytes : 0;  // mono: L = R
  for (size_t i = 0; i < frames; ++i) {
    const uint8_t* frame = data + i * frame_bytes;
    audio.stereo[2 * i] = sample(frame, format);
    audio.stereo[2 * i + 1] = sample(frame + right, format);
  }
  error = Error::kNone;
  return audio;
}

std::optional<Audio> read(const std::string& path, Error& error) {
  const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
  struct stat info {};
  if (fd < 0 || ::fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) {
    if (fd >= 0) ::close(fd);
    error = Error::kUnreadable;
    return std::nullopt;
  }
  const auto size = static_cast<size_t>(info.st_size);
  if (static_cast<uint64_t>(info.st_size) > kMaxBytes) {
    ::close(fd);
    error = Error::kTooLong;
    return std::nullopt;
  }
  if (size == 0) {  // nothing to map, and no header
    ::close(fd);
    error = Error::kNotWav;
    return std::nullopt;
  }
  // Mapped, not read into a buffer: file pages are clean and leave with the mapping, while a
  // freed buffer this large stays dirty in malloc's cache and counts in the footprint.
  void* mapped = ::mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
  ::close(fd);
  if (mapped == MAP_FAILED) {
    error = Error::kUnreadable;
    return std::nullopt;
  }
  auto audio = decode(static_cast<const uint8_t*>(mapped), size, error);
  ::munmap(mapped, size);
  return audio;
}

}  // namespace nmr::wav
