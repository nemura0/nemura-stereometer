// Core-internal: strict UTF-8 decoding (RFC 3629: no overlong forms, no surrogates, nothing past
// U+10FFFF), for validating setting text and building preset file names.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace nmr::utf8 {

struct Decoded {
  char32_t code_point;
  size_t length;  // bytes; 0 = not a valid sequence
};

// The character starting at text[at] (at < text.size()).
inline Decoded decode(std::string_view text, size_t at) noexcept {
  const auto byte = [&](size_t i) { return static_cast<uint8_t>(text[i]); };
  const uint8_t lead = byte(at);
  if (lead < 0x80) return {lead, 1};
  size_t length = 0;
  char32_t code_point = 0;
  char32_t smallest = 0;
  if ((lead & 0xE0) == 0xC0) {
    length = 2, code_point = lead & 0x1F, smallest = 0x80;
  } else if ((lead & 0xF0) == 0xE0) {
    length = 3, code_point = lead & 0x0F, smallest = 0x800;
  } else if ((lead & 0xF8) == 0xF0) {
    length = 4, code_point = lead & 0x07, smallest = 0x10000;
  } else {
    return {0, 0};
  }
  if (length > text.size() - at) return {0, 0};
  for (size_t i = 1; i < length; ++i) {
    const uint8_t next = byte(at + i);
    if ((next & 0xC0) != 0x80) return {0, 0};
    code_point = (code_point << 6) | (next & 0x3F);
  }
  if (code_point < smallest || code_point > 0x10FFFF ||
      (code_point >= 0xD800 && code_point <= 0xDFFF)) {
    return {0, 0};
  }
  return {code_point, length};
}

// C0 and C1 control characters and DEL.
inline bool isControl(char32_t code_point) noexcept {
  return code_point < 0x20 || (code_point >= 0x7F && code_point <= 0x9F);
}

// `text` without invalid sequences and control characters, cut to at most `max_bytes` without
// splitting a character.
inline std::string clean(std::string_view text, size_t max_bytes) {
  std::string result;
  for (size_t at = 0; at < text.size();) {
    const Decoded decoded = decode(text, at);
    if (decoded.length == 0) {
      ++at;
      continue;
    }
    if (!isControl(decoded.code_point)) {
      if (result.size() + decoded.length > max_bytes) break;
      result.append(text.substr(at, decoded.length));
    }
    at += decoded.length;
  }
  return result;
}

}  // namespace nmr::utf8
