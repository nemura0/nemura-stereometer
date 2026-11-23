// GPU tests of how the scope's light ends: past the scope's edges it fades instead of stopping
// at a line, and the glow is a halo around a sharp trace, not a haze over it.
#include "meter_harness.h"

namespace {

// A scope with room around it in the 200 px target, and no meters.
Layout roomyLayout() {
  Layout layout;
  layout.scope = {40, 40, 120, 120};
  return layout;
}

// The light `dx`, `dy` pixels from where `p` lands.
float lightAt(const Harness& h, ScopePoint p, float dx, float dy) {
  const auto [x, y] = h.place(p);
  return h.pixel(x + dx, y + dy).peak();
}

}  // namespace

TEST_CASE("meter light: past the scope's edges it fades, never stopping at a line") {
  Harness h;
  REQUIRE_GPU(h);
  h.setLayout(roomyLayout());
  const nmr::Rect s = h.scope();  // 40, 40, 120 × 120
  struct Edge {
    ScopePoint at;       // a point near the edge
    float in_x, in_y;    // the last pixel inside the scope, across the edge from…
    float out_x, out_y;  // …the first pixel outside it
  };
  const float mid = s.x + s.width / 2;
  const Edge edges[] = {
      {{0, 1}, mid, s.y, mid, s.y - 1},                                     // top
      {{0, -1}, mid, s.y + s.height - 1, mid, s.y + s.height},              // bottom
      {{-1, 0}, s.x, s.y + s.height / 2, s.x - 1, s.y + s.height / 2},      // left
      {{1, 0}, s.x + s.width - 1, s.y + s.height / 2, s.x + s.width, s.y + s.height / 2},
  };
  for (const float glow : {0.0f, 1.0f}) {
    for (const Edge& e : edges) {
      CAPTURE(glow);
      CAPTURE(e.at.x);
      CAPTURE(e.at.y);
      // At glow 0, a dot exactly on the edge; with glow, one just inside it.
      const float reach = glow > 0 ? 1.0f : 1.0f / MeterRenderer::kFullScale;
      const std::vector<ScopePoint> spot(64, ScopePoint{e.at.x * reach, e.at.y * reach});
      MeterFrame f = spotFrame(h, spot, glow);
      f.style.size_px = 6;
      REQUIRE(h.render(f));
      const float in = h.pixel(e.in_x, e.in_y).peak();
      const float out = h.pixel(e.out_x, e.out_y).peak();
      INFO(in << " → " << out);
      CHECK(in > 0.05f);
      CHECK(out >= 0.6f * in);  // the light goes on past the edge…
      const float far_x = e.out_x + 30 * (e.out_x - e.in_x);
      const float far_y = e.out_y + 30 * (e.out_y - e.in_y);
      CHECK(h.pixel(far_x, far_y).peak() < 0.01f);  // …and fades out before long
    }
  }
}

TEST_CASE("meter light: where it reaches the target's edge, it fades out there") {
  Harness h;
  REQUIRE_GPU(h);
  Layout layout = h.layout();
  layout.scope = {4, 4, 192, 192};  // 4 px from the top
  h.setLayout(layout);
  const std::vector<ScopePoint> spot(64, ScopePoint{0, 1 / MeterRenderer::kFullScale});
  REQUIRE(h.render(spotFrame(h, spot, 1)));
  const float x = h.place(spot[0])[0];
  const float on = h.pixel(x, 4).peak();  // the dot, on the scope's top edge
  INFO(on << " → " << h.pixel(x, 0).peak());
  CHECK(on > 0.3f);
  CHECK(h.pixel(x, 0).peak() < 0.3f * on);  // the target's first row: nearly dark
}

namespace {

// A vertical line bright enough to saturate, through the scope's center.
MeterFrame brightLine(const Harness& h, const std::vector<ScopePoint>& line, float glow) {
  MeterFrame f = h.frame();
  f.points = line;
  f.style.intensity = 1;
  f.glow = glow;
  f.clear = true;
  return f;
}

// How many pixels across the row through the scope's center are at least nearly white.
int coreWidth(const Harness& h) {
  const auto [cx, cy] = h.place({0, 0});
  int width = 0;
  for (float dx = -30; dx <= 30; ++dx) width += h.pixel(cx + dx, cy).peak() >= 0.9f ? 1 : 0;
  return width;
}

}  // namespace

TEST_CASE("meter light: glow is a halo around the trace; the trace stays as sharp") {
  Harness h;
  REQUIRE_GPU(h);
  const std::vector<ScopePoint> line = monoLine();
  REQUIRE(h.render(brightLine(h, line, 0)));
  const int sharp = coreWidth(h);
  REQUIRE(sharp >= 2);
  REQUIRE(h.render(brightLine(h, line, 1)));
  const int glowing = coreWidth(h);
  const float halo = lightAt(h, {0, 0}, 6, 0);
  INFO(sharp << " px core → " << glowing << " px with glow; halo " << halo);
  CHECK(glowing <= sharp + 2);  // the core does not swell into a blur
  CHECK(halo > 0.1f);           // the halo is there…
  CHECK(halo < 0.7f);           // …dimmer than the trace, never washing it out
}

TEST_CASE("meter light: a new light size forgets the last point, drawing no stray stroke") {
  Harness h;
  REQUIRE_GPU(h);
  h.setLayout(roomyLayout());
  MeterFrame f = h.frame();
  f.draw = DrawStyle::kLines;
  const std::vector<ScopePoint> left{{-0.8f, 0}};
  f.points = left;
  f.clear = true;
  REQUIRE(h.render(f));
  Layout bigger = roomyLayout();
  bigger.scope = {30, 30, 140, 140};  // a new light texture: a new trail
  h.setLayout(bigger);
  f.layout = bigger;
  const std::vector<ScopePoint> right{{0.8f, 0}, {0.8f, 0.01f}};
  f.points = right;
  f.clear = false;
  REQUIRE(h.render(f));
  CHECK(h.at({0, 0}).peak() < 0.02f);  // nothing joins the old trail's last point to the new
  CHECK(h.at({0.8f, 0}).peak() > 0.1f);
}

TEST_CASE("meter light: dragging the point size keeps the trail") {
  Harness h;
  REQUIRE_GPU(h);
  h.setLayout(roomyLayout());
  const std::vector<ScopePoint> spot(64, ScopePoint{0.3f, 0.3f});
  MeterFrame f = spotFrame(h, spot, 0);
  f.style.size_px = 3;
  REQUIRE(h.render(f));
  MeterFrame next = h.frame();  // no new points; the trail kept whole
  next.style.decay = 1;
  next.style.size_px = 4;
  REQUIRE(h.render(next));
  CHECK(h.at(spot[0]).peak() > 0.5f);
}
