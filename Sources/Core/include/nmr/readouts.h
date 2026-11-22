// The meters' numeric readouts as text.
//
// Correlation: two decimals with a sign ("+0.82", "-0.35"); "0.00" when it rounds to 0.
// Balance: the louder side and its lead in dB, one decimal ("L 3.0 dB", "R 60.0 dB"); "C"
// within 0.05 dB. Values that are not numbers read as 0, and all are held to −1 … 1 (balance is
// (R − L) / (R + L) of the channel powers, as dsp::StereoMeter; its dB are held to 60).
// ASCII from kReadoutGlyphs only. Render thread; no allocation.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace nmr {

inline constexpr std::string_view kReadoutGlyphs = "0123456789+-.LRCdB ";

struct ReadoutText {
  static constexpr size_t kMaxChars = 12;
  std::array<char, kMaxChars> chars{};
  uint8_t length = 0;
  [[nodiscard]] std::string_view view() const noexcept { return {chars.data(), length}; }
};

[[nodiscard]] ReadoutText correlationText(float correlation) noexcept;
[[nodiscard]] ReadoutText balanceText(float balance) noexcept;

}  // namespace nmr
