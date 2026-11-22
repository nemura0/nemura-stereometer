#include <nmr/readouts.h>

#include <algorithm>
#include <cmath>

namespace nmr {

namespace {

constexpr double kMaxBalanceDb = 60;

class Writer {
 public:
  void put(char c) noexcept {
    if (text_.length < ReadoutText::kMaxChars) text_.chars[text_.length++] = c;
  }
  void put(std::string_view s) noexcept {
    for (const char c : s) put(c);
  }
  // `value` / 10^decimals with that many decimals (value ≥ 0).
  void fixed(long value, int decimals) noexcept {
    long divisor = 1;
    for (int i = 0; i < decimals; ++i) divisor *= 10;
    whole(value / divisor);
    put('.');
    const long rest = value % divisor;
    for (long place = divisor / 10; place >= 1; place /= 10) {
      put(static_cast<char>('0' + rest / place % 10));
    }
  }
  [[nodiscard]] ReadoutText text() const noexcept { return text_; }

 private:
  void whole(long value) noexcept {
    if (value >= 10) whole(value / 10);
    put(static_cast<char>('0' + value % 10));
  }
  ReadoutText text_{};
};

float held(float value) noexcept {
  return std::isfinite(value) ? std::clamp(value, -1.0f, 1.0f) : 0;
}

}  // namespace

ReadoutText correlationText(float correlation) noexcept {
  const long hundredths = std::lround(double{held(correlation)} * 100);
  Writer w;
  if (hundredths != 0) w.put(hundredths > 0 ? '+' : '-');
  w.fixed(std::labs(hundredths), 2);
  return w.text();
}

ReadoutText balanceText(float balance) noexcept {
  const double b = held(balance);
  // R / L = (1 + b) / (1 − b); one side alone is infinitely louder, held to kMaxBalanceDb.
  const double db = std::abs(b) >= 1 ? std::copysign(kMaxBalanceDb, b)
                                     : std::clamp(10 * std::log10((1 + b) / (1 - b)),
                                                  -kMaxBalanceDb, kMaxBalanceDb);
  const long tenths = std::lround(std::abs(db) * 10);
  Writer w;
  if (tenths == 0) {
    w.put('C');
    return w.text();
  }
  w.put(db < 0 ? 'L' : 'R');
  w.put(' ');
  w.fixed(tenths, 1);
  w.put(" dB");
  return w.text();
}

}  // namespace nmr
