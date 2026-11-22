#include <nmr/meter_bars.h>

#include <doctest/doctest.h>

#include <cmath>
#include <vector>

using nmr::BarRect;
using nmr::Layout;
using nmr::MeterBars;
using nmr::meterBars;
using nmr::MeterPalette;
using nmr::Premultiplied;
using nmr::Rect;

namespace {

const MeterPalette kPalette{};

Layout bars() {
  Layout layout;
  layout.scope = {10, 10, 200, 200};
  layout.correlation_history = {10, 220, 200, 20};
  layout.correlation = {10, 250, 200, 10};
  layout.balance = {10, 270, 200, 10};
  return layout;
}

bool inside(const Rect& inner, const Rect& outer) {
  constexpr float kSlack = 1e-3f;
  return inner.x >= outer.x - kSlack && inner.y >= outer.y - kSlack &&
         inner.x + inner.width <= outer.x + outer.width + kSlack &&
         inner.y + inner.height <= outer.y + outer.height + kSlack;
}

// The rects of one color that lie in `area`.
std::vector<Rect> colored(const MeterBars& m, const Rect& area, const Premultiplied& color) {
  std::vector<Rect> found;
  for (uint32_t i = 0; i < m.count; ++i) {
    const BarRect& r = m.rects[i];
    if (r.color == color && inside(r.rect, area)) found.push_back(r.rect);
  }
  return found;
}

}  // namespace

TEST_CASE("meter bars: nothing for meters that are off") {
  const Layout layout{.scope = {0, 0, 100, 100}};
  CHECK(meterBars(layout, 0.5f, 0.5f, {}).count == 0);
}

TEST_CASE("meter bars: each bar has its track and a center mark") {
  const Layout layout = bars();
  const MeterBars m = meterBars(layout, 0, 0, {});
  for (const Rect& bar : {layout.correlation, layout.balance}) {
    const auto track = colored(m, bar, kPalette.track);
    REQUIRE(track.size() == 1);
    CHECK(track[0] == bar);
    const auto center = colored(m, bar, kPalette.center);
    REQUIRE(center.size() == 1);
    CHECK(center[0].x + center[0].width / 2 == doctest::Approx(bar.x + bar.width / 2));
    CHECK(center[0].width == doctest::Approx(bar.height * MeterBars::kCenterShare));
    CHECK(center[0].height == bar.height);
  }
}

TEST_CASE("meter bars: correlation fills from the center toward its value") {
  const Layout layout = bars();
  const Rect& bar = layout.correlation;
  const float middle = bar.x + bar.width / 2;
  {
    const auto fill = colored(meterBars(layout, 0.5f, 0, {}), bar, kPalette.positive);
    REQUIRE(fill.size() == 1);
    CHECK(fill[0].x == doctest::Approx(middle));
    CHECK(fill[0].width == doctest::Approx(bar.width / 4));
    CHECK(fill[0].y == bar.y);
    CHECK(fill[0].height == bar.height);
  }
  {
    const auto fill = colored(meterBars(layout, -1, 0, {}), bar, kPalette.negative);
    REQUIRE(fill.size() == 1);
    CHECK(fill[0].x == doctest::Approx(bar.x));
    CHECK(fill[0].width == doctest::Approx(bar.width / 2));
  }
  // No fill at 0; out of range and NaN are held.
  CHECK(colored(meterBars(layout, 0, 0, {}), bar, kPalette.positive).empty());
  CHECK(colored(meterBars(layout, NAN, 0, {}), bar, kPalette.positive).empty());
  const auto over = colored(meterBars(layout, 7, 0, {}), bar, kPalette.positive);
  REQUIRE(over.size() == 1);
  CHECK(over[0].width == doctest::Approx(bar.width / 2));
}

TEST_CASE("meter bars: balance fills toward the louder side") {
  const Layout layout = bars();
  const Rect& bar = layout.balance;
  const float middle = bar.x + bar.width / 2;
  const auto right = colored(meterBars(layout, 0, 0.25f, {}), bar, kPalette.positive);
  REQUIRE(right.size() == 1);
  CHECK(right[0].x == doctest::Approx(middle));
  CHECK(right[0].width == doctest::Approx(bar.width / 8));
  const auto left = colored(meterBars(layout, 0, -0.5f, {}), bar, kPalette.positive);
  REQUIRE(left.size() == 1);
  CHECK(left[0].x == doctest::Approx(middle - bar.width / 4));
  CHECK(left[0].width == doctest::Approx(bar.width / 4));
  CHECK(colored(meterBars(layout, 0, 0, {}), bar, kPalette.negative).empty());
}

TEST_CASE("meter bars: the history rises for positive values and falls for negative ones") {
  const Layout layout = bars();
  const Rect& strip = layout.correlation_history;
  const float middle = strip.y + strip.height / 2;
  const std::vector<float> history{1, -0.5f, 0, NAN};
  const MeterBars m = meterBars(layout, 0, 0, history);
  const auto track = colored(m, strip, kPalette.track);
  REQUIRE(track.size() == 1);
  CHECK(track[0] == strip);
  const auto up = colored(m, strip, kPalette.positive);
  const auto down = colored(m, strip, kPalette.negative);
  REQUIRE(up.size() == 1);
  REQUIRE(down.size() == 1);
  const float column = strip.width / 4;
  CHECK(up[0].x == doctest::Approx(strip.x));  // the oldest, at the left
  CHECK(up[0].width == doctest::Approx(column));
  CHECK(up[0].y == doctest::Approx(strip.y));
  CHECK(up[0].height == doctest::Approx(strip.height / 2));
  CHECK(down[0].x == doctest::Approx(strip.x + column));
  CHECK(down[0].y == doctest::Approx(middle));
  CHECK(down[0].height == doctest::Approx(strip.height / 4));
}

TEST_CASE("meter bars: at most one history column per pixel, the newest") {
  Layout layout = bars();
  layout.correlation_history.width = 50;
  std::vector<float> history(120, -1.0f);
  history.back() = 1;  // the newest
  const MeterBars m = meterBars(layout, 0, 0, history);
  const auto up = colored(m, layout.correlation_history, kPalette.positive);
  const auto down = colored(m, layout.correlation_history, kPalette.negative);
  REQUIRE(up.size() == 1);
  CHECK(down.size() == 49);
  CHECK(up[0].x + up[0].width == doctest::Approx(60));  // at the right edge
  CHECK(up[0].width == doctest::Approx(1));
}

TEST_CASE("meter bars: a long history fits the rect limit") {
  Layout layout = bars();
  layout.correlation_history.width = 4000;
  const std::vector<float> history(5000, 0.5f);
  const MeterBars m = meterBars(layout, 1, 1, history);
  CHECK(m.count <= MeterBars::kMaxRects);
  const auto up = colored(m, layout.correlation_history, kPalette.positive);
  CHECK(up.size() == MeterBars::kMaxHistory);
  for (uint32_t i = 0; i < m.count; ++i) CHECK(inside(m.rects[i].rect, {0, 0, 5000, 400}));
}

TEST_CASE("meter bars: history columns meet on whole pixels, leaving no seams") {
  Layout layout = bars();
  layout.correlation_history = {10.3f, 220, 7, 20};
  const std::vector<float> history{0.5f, 0.5f, 0.5f};
  // (Edges round to the nearest pixel, so the first may start a little before the strip.)
  const auto up = colored(meterBars(layout, 0, 0, history), {0, 200, 100, 50}, kPalette.positive);
  REQUIRE(up.size() == 3);
  float edge = std::round(10.3f);
  for (const Rect& column : up) {
    CHECK(column.x == edge);
    CHECK(column.width == std::round(column.width));
    edge = column.x + column.width;
  }
  CHECK(edge == std::round(10.3f + 7));
}
