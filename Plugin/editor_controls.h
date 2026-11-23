// The editor's controls, built from stock AppKit controls: the top bar and the settings panel
// generated from the schema. Every control that edits a setting carries an identifier (the bar's:
// "send", "mode", "preset", "response"; the panel's: the setting's key), so one action reads any
// of them back and one pass shows the current settings in all of them. Main thread only.
#pragma once

#import <AppKit/AppKit.h>

#include <nmr/instance_sender.h>
#include <nmr/settings.h>

#include <optional>

namespace nmr::plugin {

// The bar along the top of `frame` (its full width, Editor::kBarHeight tall). Controls send
// `changed` to `target`; the gear sends `gear`. The preset menu's delegate is `target`.
NSView* makeTopBar(NSRect frame, id target, SEL changed, SEL gear);

// Hides the bar's menus that do not fit an editor `width` points wide (they are also in the
// settings panel).
void fitTopBar(NSView* bar, CGFloat width);

// The panel with a row per setting the plugin uses (every entry not only for the app), in
// groups, scrolling. Controls send `changed` to `target`; the colormap menu's delegate is
// `target`.
NSView* makeSettingsPanel(NSRect frame, id target, SEL changed);

// Shows `current` in every control under `root` (a text field being edited keeps its text).
void showSettings(NSView* root, const settings::Settings& current);

// The settings with `control`'s new value in them, or nothing when it names no setting.
std::optional<settings::Settings> readControl(NSControl* control,
                                              const settings::Settings& current);

// Lists the user's files again (presets and colormaps) in the menus under `root`, then shows
// `current` (a menu is about to open: the folders may have changed).
void refillMenus(NSView* root, const settings::Settings& current);

// The status dot: its color, tooltip and accessibility value.
void showSendState(NSView* dot, InstanceSender::State state);

}  // namespace nmr::plugin
