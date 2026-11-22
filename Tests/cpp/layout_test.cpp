#include <nmr/layout.h>

#include <doctest/doctest.h>

#include <algorithm>
#include <cmath>

using nmr::Layout;
using nmr::layout;
using nmr::LayoutInput;
using nmr::LayoutMetrics;
using nmr::Rect;

namespace {

bool inside(const Rect& inner, float width, float height) {
  return inner.x >= 0 && inner.y >= 0 && inner.x + inner.width <= width + 1e-3f &&
         inner.y + inner.height <= height + 1e-3f;
}

bool apart(const Rect& a, const Rect& b) {
  if (a.empty() || b.empty()) return true;
  return a.x + a.width <= b.x + 1e-3f || b.x + b.width <= a.x + 1e-3f ||
         a.y + a.height <= b.y + 1e-3f || b.y + b.height <= a.y + 1e-3f;
}

}  // namespace

TEST_CASE("layout: a square scope centered above the meters") {
  const Layout l = layout({.width = 800, .height = 900, .scale = 2});
  CHECK(l.scope.width == doctest::Approx(l.scope.height));
  CHECK(l.scope.x + l.scope.width / 2 == doctest::Approx(400));
  CHECK(!l.correlation.empty());
  CHECK(!l.correlation_history.empty());
  CHECK(!l.balance.empty());
  CHECK(l.correlation_readout.empty());
  CHECK(l.balance_readout.empty());
  // Top to bottom: scope, history, correlation, balance.
  CHECK(l.scope.y + l.scope.height <= l.correlation_history.y + 1e-3f);
  CHECK(l.correlation_history.y + l.correlation_history.height <= l.correlation.y + 1e-3f);
  CHECK(l.correlation.y + l.correlation.height <= l.balance.y + 1e-3f);
  // Margins of 3 % of the smaller side all round.
  const float margin = 0.03f * 800;
  CHECK(l.balance.y + l.balance.height == doctest::Approx(900 - margin));
  CHECK(l.balance.x == doctest::Approx(margin));
  CHECK(l.balance.width == doctest::Approx(800 - 2 * margin));
  CHECK(l.correlation.width == doctest::Approx(l.balance.width));
  CHECK(l.correlation_history.width == doctest::Approx(l.balance.width));
  // Bars: 3.5 % of the smaller side (28 px = 14 pt, held to 10 pt = 20 px).
  CHECK(l.correlation.height == doctest::Approx(20));
  CHECK(l.balance.height == doctest::Approx(20));
  CHECK(l.correlation_history.height == doctest::Approx(40));
  for (const Rect& r : {l.scope, l.correlation_history, l.correlation, l.balance}) {
    CHECK(inside(r, 800, 900));
  }
}

TEST_CASE("layout: bars follow the view between 4 and 10 points") {
  CHECK(layout({.width = 300, .height = 300, .scale = 2}).correlation.height ==
        doctest::Approx(0.035f * 300));
  CHECK(layout({.width = 200, .height = 400, .scale = 2}).balance.height == doctest::Approx(8));
  CHECK(layout({.width = 2000, .height = 2000, .scale = 1}).balance.height ==
        doctest::Approx(10));
}

TEST_CASE("layout: the half modes get a 2:1 scope") {
  const Layout wide = layout({.width = 1000, .height = 600, .half = true});
  CHECK(wide.scope.width == doctest::Approx(2 * wide.scope.height));
  CHECK(wide.scope.width == doctest::Approx(1000 - 2 * 0.03f * 600));  // as wide as it can be
  CHECK(wide.scope.x + wide.scope.width / 2 == doctest::Approx(500));
  const Layout tall = layout({.width = 400, .height = 900, .half = true});
  CHECK(tall.scope.width == doctest::Approx(400 - 2 * 0.03f * 400));
  CHECK(tall.scope.width == doctest::Approx(2 * tall.scope.height));
}

TEST_CASE("layout: the scope takes what the meters leave, centered in it") {
  const Layout wide = layout({.width = 1600, .height = 500, .scale = 1});
  const float margin = 0.03f * 500;
  CHECK(wide.scope.y == doctest::Approx(margin));
  CHECK(wide.scope.height == doctest::Approx(wide.correlation_history.y - wide.scope.y -
                                             LayoutMetrics::kGapBars * wide.balance.height));
  CHECK(wide.scope.x + wide.scope.width / 2 == doctest::Approx(800));
  // A tall view: the square scope is centered in the height the meters leave.
  const Layout tall = layout({.width = 400, .height = 900, .scale = 1});
  const float top = 0.03f * 400;
  const float bottom = tall.correlation_history.y - LayoutMetrics::kGapBars * tall.balance.height;
  CHECK(tall.scope.y + tall.scope.height / 2 == doctest::Approx((top + bottom) / 2));
  const Layout none = layout({.width = 500, .height = 500, .correlation = false,
                              .balance = false});
  CHECK(none.scope.width == doctest::Approx(500 - 2 * margin));
  CHECK(none.scope.height == doctest::Approx(500 - 2 * margin));
  CHECK(none.correlation.empty());
  CHECK(none.correlation_history.empty());
  CHECK(none.balance.empty());
}

TEST_CASE("layout: each meter can be off") {
  const Layout corr = layout({.width = 500, .height = 600, .balance = false});
  CHECK(!corr.correlation.empty());
  CHECK(corr.balance.empty());
  CHECK(corr.correlation.y + corr.correlation.height == doctest::Approx(600 - 0.03f * 500));
  const Layout bal = layout({.width = 500, .height = 600, .correlation = false});
  CHECK(bal.correlation.empty());
  CHECK(bal.correlation_history.empty());
  CHECK(!bal.balance.empty());
  CHECK(bal.scope.y + bal.scope.height <= bal.balance.y + 1e-3f);
}

TEST_CASE("layout: readouts sit right of their bars") {
  const Layout l = layout({.width = 600, .height = 700, .readouts = true});
  for (auto [bar, readout] : {std::pair{l.correlation, l.correlation_readout},
                              std::pair{l.balance, l.balance_readout}}) {
    CHECK(!readout.empty());
    CHECK(readout.y == doctest::Approx(bar.y));
    CHECK(readout.height == doctest::Approx(bar.height));
    CHECK(readout.width == doctest::Approx(LayoutMetrics::kReadoutBars * bar.height));
    CHECK(bar.x + bar.width + LayoutMetrics::kGapBars * bar.height == doctest::Approx(readout.x));
    CHECK(readout.x + readout.width == doctest::Approx(600 - 0.03f * 600));
    CHECK(apart(bar, readout));
  }
  CHECK(l.correlation_history.width == doctest::Approx(l.correlation.width));
}

TEST_CASE("layout: a view too short for the meters drops them") {
  const Layout l = layout({.width = 1000, .height = 40, .scale = 1});
  CHECK(l.correlation.empty());
  CHECK(l.balance.empty());
  CHECK(l.correlation_history.empty());
  CHECK(l.scope.height == doctest::Approx(40 - 2 * 0.03f * 40));
}

TEST_CASE("layout: parts never overlap and stay in the view") {
  for (float width : {1.0f, 24.0f, 120.0f, 360.0f, 949.0f, 3000.0f}) {
    for (float height : {1.0f, 24.0f, 120.0f, 360.0f, 949.0f, 3000.0f}) {
      for (bool half : {false, true}) {
        for (bool readouts : {false, true}) {
          CAPTURE(width);
          CAPTURE(height);
          const Layout l = layout({.width = width, .height = height, .scale = 2, .half = half,
                                   .readouts = readouts});
          const Rect parts[] = {l.scope, l.correlation_history, l.correlation,
                                l.correlation_readout, l.balance, l.balance_readout};
          for (const Rect& a : parts) {
            if (a.empty()) continue;
            CHECK(inside(a, width, height));
            for (const Rect& b : parts) {
              if (&a != &b) CHECK(apart(a, b));
            }
          }
          CHECK(!l.scope.empty());
        }
      }
    }
  }
}

TEST_CASE("layout: an empty or broken view has nothing to draw") {
  for (auto [w, h] : {std::pair{0.0f, 100.0f}, std::pair{100.0f, -1.0f},
                      std::pair{NAN, 100.0f}, std::pair{100.0f, INFINITY}}) {
    const Layout l = layout({.width = w, .height = h});
    CHECK(l.scope.empty());
    CHECK(l.correlation.empty());
    CHECK(l.balance.empty());
  }
  const Layout bad_scale = layout({.width = 400, .height = 400, .scale = NAN});
  CHECK(!bad_scale.scope.empty());
  CHECK(bad_scale.balance.height == doctest::Approx(10));  // 14 px, held to 10 pt at scale 1
}

TEST_CASE("layout: a view too narrow for the readouts drops them, keeping the bars") {
  // 80 px: a readout (5 bars of 8 px) and its gap would leave the bar 29 of 75 px.
  const Layout l = layout({.width = 80, .height = 900, .scale = 2, .readouts = true});
  CHECK(!l.correlation.empty());
  CHECK(!l.balance.empty());
  CHECK(l.correlation_readout.empty());
  CHECK(l.balance_readout.empty());
  CHECK(l.correlation.width == doctest::Approx(80 - 2 * 0.03f * 80));
  // Wide enough: a bar keeps at least half its row.
  const Layout wide = layout({.width = 400, .height = 900, .scale = 2, .readouts = true});
  CHECK(!wide.balance_readout.empty());
  CHECK(wide.balance.width >= 0.5f * (400 - 2 * 0.03f * 400));
}
