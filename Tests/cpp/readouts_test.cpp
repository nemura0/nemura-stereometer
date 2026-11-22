#include <nmr/readouts.h>

#include <doctest/doctest.h>

#include <cmath>
#include <limits>
#include <string>
#include <string_view>

using nmr::balanceText;
using nmr::correlationText;
using nmr::kReadoutGlyphs;
using nmr::ReadoutText;

namespace {

std::string text(const ReadoutText& t) { return std::string(t.view()); }

// The balance (R − L) / (R + L) of channel powers whose ratio R / L is `db` decibels.
float balanceOfDb(double db) {
  const double ratio = std::pow(10.0, db / 10);
  return static_cast<float>((ratio - 1) / (ratio + 1));
}

}  // namespace

TEST_CASE("readouts: correlation shows two decimals and its sign") {
  CHECK(text(correlationText(0.823f)) == "+0.82");
  CHECK(text(correlationText(-0.354f)) == "-0.35");
  CHECK(text(correlationText(0.996f)) == "+1.00");
  CHECK(text(correlationText(1)) == "+1.00");
  CHECK(text(correlationText(-1)) == "-1.00");
  CHECK(text(correlationText(0.05f)) == "+0.05");
}

TEST_CASE("readouts: correlation near 0 reads 0.00, with no sign") {
  CHECK(text(correlationText(0)) == "0.00");
  CHECK(text(correlationText(0.004f)) == "0.00");
  CHECK(text(correlationText(-0.004f)) == "0.00");
}

TEST_CASE("readouts: correlation out of range or not a number is held") {
  CHECK(text(correlationText(3)) == "+1.00");
  CHECK(text(correlationText(-3)) == "-1.00");
  CHECK(text(correlationText(std::numeric_limits<float>::quiet_NaN())) == "0.00");
  CHECK(text(correlationText(std::numeric_limits<float>::infinity())) == "0.00");
}

TEST_CASE("readouts: balance names the louder side and its lead in dB") {
  CHECK(text(balanceText(balanceOfDb(3))) == "R 3.0 dB");
  CHECK(text(balanceText(balanceOfDb(-3))) == "L 3.0 dB");
  CHECK(text(balanceText(balanceOfDb(12.34))) == "R 12.3 dB");
  CHECK(text(balanceText(balanceOfDb(-0.26))) == "L 0.3 dB");
}

TEST_CASE("readouts: balance within 0.05 dB is centered") {
  CHECK(text(balanceText(0)) == "C");
  CHECK(text(balanceText(balanceOfDb(0.04))) == "C");
  CHECK(text(balanceText(balanceOfDb(-0.04))) == "C");
}

TEST_CASE("readouts: balance at one side only reads 60 dB; not a number is centered") {
  CHECK(text(balanceText(1)) == "R 60.0 dB");
  CHECK(text(balanceText(-1)) == "L 60.0 dB");
  CHECK(text(balanceText(5)) == "R 60.0 dB");
  CHECK(text(balanceText(balanceOfDb(80))) == "R 60.0 dB");
  CHECK(text(balanceText(std::numeric_limits<float>::quiet_NaN())) == "C");
}

TEST_CASE("readouts: every character is in the glyph set") {
  const std::string_view glyphs = kReadoutGlyphs;
  for (const float v : {-1.0f, -0.5f, 0.0f, 0.123f, 0.9f, 1.0f}) {
    for (const ReadoutText& t : {correlationText(v), balanceText(v)}) {
      CAPTURE(text(t));
      CHECK(t.length <= ReadoutText::kMaxChars);
      for (const char c : t.view()) CHECK(glyphs.find(c) != std::string_view::npos);
    }
  }
}
