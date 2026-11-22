// WAV files as interleaved stereo float32, for `--feed` and the snapshot tool: PCM 16, 24 and
// 32 bit, float 32 and 64 bit, plain or WAVE_FORMAT_EXTENSIBLE. Mono plays on both channels;
// of more channels, the first two are kept. Not for audio threads (it allocates).
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace nmr::wav {

inline constexpr size_t kMaxBytes = size_t{1} << 31;  // 2 GiB of file
// 2^27 frames, 1 GiB decoded: about 46 minutes at 48 kHz, whatever the file's format.
inline constexpr uint64_t kMaxFrames = uint64_t{1} << 27;

enum class Error {
  kNone,
  kUnreadable,   // missing, not a regular file, or unreadable
  kNotWav,       // no RIFF/WAVE header
  kUnsupported,  // a sample format or rate it does not play
  kEmpty,        // no whole frame of audio
  kTooLong,      // over kMaxBytes of file or kMaxFrames of audio
};

struct Audio {
  double sample_rate = 0;
  std::vector<float> stereo;  // interleaved L, R

  [[nodiscard]] uint64_t frames() const noexcept { return stereo.size() / 2; }
};

std::optional<Audio> decode(const uint8_t* bytes, size_t size, Error& error,
                           uint64_t max_frames = kMaxFrames);
std::optional<Audio> read(const std::string& path, Error& error);

}  // namespace nmr::wav
