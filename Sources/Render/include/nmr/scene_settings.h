// What a meter view draws from the stored settings (nmr::settings): the bridge between the
// schema and MeterScene. The colormap is resolved by the caller (a user's .map is a file read),
// and the host decides the background: the app's may be transparent, a plugin editor's never is.
// ObjC++ only (MeterSettings lives with the scene).
#pragma once

#include <nmr/colormap.h>
#include <nmr/meter_scene.h>
#include <nmr/settings.h>

#include <cstdint>

namespace nmr {

enum class SceneHost : uint8_t { kApp, kPlugin };

// The NEMURA look (the `original` mode, Iris Bloom): what the mode adds beyond the settings.
inline constexpr float kNemuraWhiten = 0.2f;
inline constexpr uint32_t kNemuraWarning = 0xE03C60FF;  // the glow's tint toward antiphase

[[nodiscard]] MeterSettings meterSettings(const settings::Settings& s, SceneHost host,
                                          const colormap::Table& colormap);

}  // namespace nmr
