#include "editor_controls.h"

#include <nmr/colormap.h>
#include <nmr/objc_names.h>
#include <nmr/presets.h>
#include <nmr/settings_json.h>

#include <algorithm>
#include <cmath>
#include <string>

#include "editor.h"

// A clip view that lays its document out from the top, as a settings list reads.
@interface NMR_OBJC(TopClipView) : NSClipView
@end

@implementation NMR_OBJC(TopClipView)
- (BOOL)isFlipped {
  return YES;
}
@end

namespace nmr::plugin {

namespace {

namespace st = settings;

constexpr CGFloat kPanelInset = 12;
constexpr CGFloat kSliderWidth = 140;
constexpr CGFloat kMenuMinWidth = 64;
constexpr CGFloat kMenuMaxWidth = 130;
constexpr CGFloat kValueWidth = 64;  // the widest value ("1000 ms") without the row moving
NSString* const kCustom = @"Custom";
NSString* const kValueSuffix = @".value";  // a slider's value label: "<key>.value"

NSString* str(std::string_view text) {
  return [[NSString alloc] initWithBytes:text.data()
                                  length:text.size()
                                encoding:NSUTF8StringEncoding];
}

std::string text(NSString* value) { return value.UTF8String != nullptr ? value.UTF8String : ""; }

NSColor* barColor() { return [NSColor colorWithSRGBRed:0.07 green:0.07 blue:0.09 alpha:1]; }

// Ranges a hundredfold wide or more (the trail, the meter integration) slide on a log scale.
bool isLog(const st::Spec& spec) { return spec.min > 0 && spec.max / spec.min >= 100; }

double toSlider(const st::Spec& spec, double value) {
  return isLog(spec) ? std::log10(value) : value;
}

// On the setting's steps: a slider moves continuously, the setting does not.
double fromSlider(const st::Spec& spec, double position) {
  const double value = isLog(spec) ? std::pow(10.0, position) : position;
  return spec.step > 0 ? std::round(value / spec.step) * spec.step : value;
}

NSString* formatValue(const st::Spec& spec, double value) {
  const int decimals = spec.step >= 1 ? 0 : 1;
  NSString* unit = spec.unit[0] != '\0' ? [@" " stringByAppendingString:@(spec.unit)] : @"";
  return [NSString stringWithFormat:@"%.*f%@", decimals, value, unit];
}

NSColor* colorOf(uint32_t rgba) {
  return [NSColor colorWithSRGBRed:((rgba >> 24) & 0xFF) / 255.0
                             green:((rgba >> 16) & 0xFF) / 255.0
                              blue:((rgba >> 8) & 0xFF) / 255.0
                             alpha:(rgba & 0xFF) / 255.0];
}

std::optional<uint32_t> rgbaOf(NSColor* color) {
  NSColor* srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (srgb == nil) return std::nullopt;  // a pattern or a catalog color with no sRGB form
  const auto byte = [](CGFloat v) {
    return static_cast<uint32_t>(std::lround(std::clamp(v, CGFloat{0}, CGFloat{1}) * 255));
  };
  return byte(srgb.redComponent) << 24 | byte(srgb.greenComponent) << 16 |
         byte(srgb.blueComponent) << 8 | byte(srgb.alphaComponent);
}

NSTextField* label(NSString* title, bool bold = false) {
  NSTextField* field = [NSTextField labelWithString:title];
  field.font = bold ? [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize]
                    : [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  field.textColor = bold ? NSColor.labelColor : NSColor.secondaryLabelColor;
  return field;
}

NSPopUpButton* popup(NSString* identifier, id target, SEL action) {
  NSPopUpButton* button = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  button.identifier = identifier;
  button.controlSize = NSControlSizeSmall;
  button.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  button.target = target;
  button.action = action;
  return button;
}

void addItem(NSPopUpButton* button, NSString* title, id represented) {
  [button addItemWithTitle:title];
  button.lastItem.representedObject = represented;
}

// A disabled "Custom" item, selected when the value matches no other item.
void addCustomItem(NSPopUpButton* button) {
  addItem(button, kCustom, nil);
  button.lastItem.enabled = NO;
  button.autoenablesItems = NO;
}

void fillPresetMenu(NSMenu* menu);

void fillChoices(NSPopUpButton* button, const st::Spec& spec) {
  for (const st::Choice& choice : spec.choices) addItem(button, @(choice.label), @(choice.key));
}

void fillColormaps(NSPopUpButton* button, std::string_view current) {
  [button removeAllItems];
  for (const colormap::Builtin& map : colormap::builtins()) {
    addItem(button, str(map.label), str(map.key));
  }
  bool listed = colormap::findBuiltin(current) != nullptr;
  for (const UserFile& file : colormap::list(colormap::directory())) {
    const std::string key = colormap::userKey(file.name);
    addItem(button, str(file.name), str(key));
    listed = listed || key == current;
  }
  if (!listed) addItem(button, str(current), str(current));  // a map no longer in the folder
}

void select(NSPopUpButton* button, id represented) {
  for (NSMenuItem* item in button.itemArray) {
    if ([item.representedObject isEqual:represented]) {
      [button selectItem:item];
      return;
    }
  }
  [button selectItemWithTitle:kCustom];
}

NSView* findView(NSView* root, NSString* identifier) {
  if ([root.identifier isEqualToString:identifier]) return root;
  for (NSView* child in root.subviews) {
    if (NSView* found = findView(child, identifier)) return found;
  }
  return nil;
}

NSView* row(NSArray<NSView*>* views) {
  NSStackView* stack = [NSStackView stackViewWithViews:views];
  stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  stack.spacing = 6;
  return stack;
}

// One setting's control in the panel (its label goes in the column before, but a checkbox's).
NSView* settingControl(const st::Spec& spec, id target, SEL changed) {
  NSString* key = @(spec.key);
  switch (spec.type) {
    case st::Type::kBool: {
      NSButton* box = [NSButton checkboxWithTitle:@(spec.label) target:target action:changed];
      box.identifier = key;
      box.controlSize = NSControlSizeSmall;
      box.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
      return box;
    }
    case st::Type::kInt:
    case st::Type::kFloat: {
      NSSlider* slider = [NSSlider sliderWithValue:toSlider(spec, spec.default_value)
                                          minValue:toSlider(spec, spec.min)
                                          maxValue:toSlider(spec, spec.max)
                                            target:target
                                            action:changed];
      slider.identifier = key;
      slider.controlSize = NSControlSizeSmall;
      slider.continuous = YES;
      [slider.widthAnchor constraintEqualToConstant:kSliderWidth].active = YES;
      NSTextField* value = label(formatValue(spec, spec.default_value));
      value.identifier = [key stringByAppendingString:kValueSuffix];
      [value.widthAnchor constraintEqualToConstant:kValueWidth].active = YES;
      return row(@[ slider, value ]);
    }
    case st::Type::kChoice: {
      NSPopUpButton* button = popup(key, target, changed);
      fillChoices(button, spec);
      return button;
    }
    case st::Type::kColor: {
      NSColorWell* well = [NSColorWell colorWellWithStyle:NSColorWellStyleMinimal];
      well.identifier = key;
      well.target = target;
      well.action = changed;
      return well;
    }
    case st::Type::kText: {
      if (std::string_view(spec.key) == "colormap") {
        NSPopUpButton* button = popup(key, target, changed);
        button.menu.delegate = target;
        fillColormaps(button, colormap::kDefaultKey);
        return button;
      }
      NSTextField* field = [NSTextField textFieldWithString:@""];
      field.identifier = key;
      field.controlSize = NSControlSizeSmall;
      field.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
      field.placeholderString = @"From the track";
      field.target = target;
      field.action = changed;
      field.cell.sendsActionOnEndEditing = YES;
      [field.widthAnchor constraintEqualToConstant:kSliderWidth].active = YES;
      return field;
    }
  }
  return [[NSView alloc] init];
}

void showControl(NSView* view, const st::Settings& current) {
  NSString* identifier = view.identifier;
  if (identifier.length == 0) return;
  if ([identifier isEqualToString:@"send"]) {
    ((NSButton*)view).state = current.flag(st::Id::kSendToApp) ? NSControlStateValueOn
                                                               : NSControlStateValueOff;
    return;
  }
  if ([identifier isEqualToString:@"response"]) {
    select((NSPopUpButton*)view, @(current.number(st::Id::kTrailMs)));
    return;
  }
  if ([identifier isEqualToString:@"preset"]) {
    NSPopUpButton* button = (NSPopUpButton*)view;
    for (NSMenuItem* item in button.itemArray) {
      NSString* json = item.representedObject;
      if (json == nil) continue;
      st::Report report;
      const auto preset = st::decodePreset(text(json), report);
      if (preset && st::applyPreset(current, preset->settings) == current) {
        [button selectItem:item];
        return;
      }
    }
    [button selectItemWithTitle:kCustom];
    return;
  }
  if ([identifier hasSuffix:kValueSuffix]) {
    const std::string key = text([identifier substringToIndex:identifier.length -
                                                              kValueSuffix.length]);
    if (const auto id = st::find(key)) {
      ((NSTextField*)view).stringValue = formatValue(st::spec(*id), current.number(*id));
    }
    return;
  }
  const auto id = st::find(text(identifier));
  if (!id) return;
  const st::Spec& spec = st::spec(*id);
  switch (spec.type) {
    case st::Type::kBool:
      ((NSButton*)view).state = current.flag(*id) ? NSControlStateValueOn : NSControlStateValueOff;
      break;
    case st::Type::kInt:
    case st::Type::kFloat:
      ((NSSlider*)view).doubleValue = toSlider(spec, current.number(*id));
      break;
    case st::Type::kChoice:
      select((NSPopUpButton*)view, str(current.choiceKey(*id)));
      break;
    case st::Type::kColor:
      // Not the well being edited: the color panel would lose its hue at zero brightness.
      if (!((NSColorWell*)view).active) ((NSColorWell*)view).color = colorOf(current.color(*id));
      break;
    case st::Type::kText:
      if ([view isKindOfClass:[NSPopUpButton class]]) {  // the colormap
        NSPopUpButton* button = (NSPopUpButton*)view;
        NSString* key = str(current.text(*id));
        if ([button indexOfItemWithRepresentedObject:key] < 0) addItem(button, key, key);
        select(button, key);
      } else if (((NSTextField*)view).currentEditor == nil) {  // not while being typed in
        ((NSTextField*)view).stringValue = str(current.text(*id));
      }
      break;
  }
}

}  // namespace

NSView* makeTopBar(NSRect frame, id target, SEL changed, SEL gear) {
  NSView* bar = [[NSView alloc] initWithFrame:frame];
  bar.identifier = @"topbar";
  bar.wantsLayer = YES;
  bar.layer.backgroundColor = barColor().CGColor;
  bar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

  NSView* dot = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 8, 8)];
  dot.identifier = @"status";
  dot.wantsLayer = YES;
  dot.layer.cornerRadius = 4;
  [dot.widthAnchor constraintEqualToConstant:8].active = YES;
  [dot.heightAnchor constraintEqualToConstant:8].active = YES;
  showSendState(dot, InstanceSender::State::kOff);

  NSButton* send = [NSButton checkboxWithTitle:@"Send to app" target:target action:changed];
  send.identifier = @"send";
  send.controlSize = NSControlSizeSmall;
  send.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];

  NSPopUpButton* mode = popup(@"mode", target, changed);
  fillChoices(mode, st::spec(st::Id::kMode));
  mode.toolTip = @"Display mode";

  NSPopUpButton* preset = popup(@"preset", target, changed);
  preset.menu.delegate = target;
  fillPresetMenu(preset.menu);
  preset.toolTip = @"Preset";

  NSPopUpButton* response = popup(@"response", target, changed);
  for (const st::Stop& stop : st::spec(st::Id::kTrailMs).stops) {
    addItem(response, @(stop.label), @(stop.value));
  }
  addCustomItem(response);
  response.toolTip = @"Response";

  NSButton* gearButton =
      [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"gearshape"
                                          accessibilityDescription:@"Settings"]
                         target:target
                         action:gear];
  gearButton.identifier = @"gear";
  gearButton.bordered = NO;
  gearButton.toolTip = @"Settings";

  // The menus give way first: they shorten their titles down to kMenuMinWidth (fitTopBar hides
  // them in narrower editors).
  for (NSView* menu in @[ mode, preset, response ]) {
    [menu setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    [menu setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    [menu.widthAnchor constraintLessThanOrEqualToConstant:kMenuMaxWidth].active = YES;
    [menu.widthAnchor constraintGreaterThanOrEqualToConstant:kMenuMinWidth].active = YES;
  }
  NSStackView* stack = [NSStackView stackViewWithViews:@[ dot, send, mode, preset, response ]];
  stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  stack.spacing = 8;
  stack.edgeInsets = NSEdgeInsetsMake(0, 10, 0, 8);
  [stack addView:gearButton inGravity:NSStackViewGravityTrailing];
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [bar addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:bar.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
  ]];
  return bar;
}

NSView* makeSettingsPanel(NSRect frame, id target, SEL changed) {
  NSGridView* grid = [NSGridView gridViewWithNumberOfColumns:2 rows:0];
  grid.columnSpacing = 8;
  grid.rowSpacing = 6;
  grid.rowAlignment = NSGridRowAlignmentNone;
  for (size_t g = 0; g < st::kGroupCount; ++g) {
    const auto group = static_cast<st::Group>(g);
    bool first = true;
    for (const st::Spec& spec : st::schema()) {
      if (spec.group != group || spec.scope == st::Scope::kApp) continue;
      if (first) {
        NSGridRow* header = [grid addRowWithViews:@[ label(@(st::group(group).label), true) ]];
        [header mergeCellsInRange:NSMakeRange(0, 2)];
        [header cellAtIndex:0].xPlacement = NSGridCellPlacementLeading;
        header.topPadding = grid.numberOfRows > 1 ? 10 : 0;
        header.bottomPadding = 2;
        first = false;
      }
      NSView* control = settingControl(spec, target, changed);
      NSView* name = spec.type == st::Type::kBool ? NSGridCell.emptyContentView
                                                  : label(@(spec.label));
      NSGridRow* row = [grid addRowWithViews:@[ name, control ]];
      row.yPlacement = NSGridCellPlacementCenter;
    }
  }
  [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  [grid columnAtIndex:1].xPlacement = NSGridCellPlacementLeading;
  NSStackView* list = [NSStackView stackViewWithViews:@[ grid ]];
  list.edgeInsets = NSEdgeInsetsMake(kPanelInset, kPanelInset, kPanelInset, kPanelInset);
  list.translatesAutoresizingMaskIntoConstraints = NO;

  NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:frame];
  scroll.identifier = @"settings";
  scroll.contentView = [[NMR_OBJC(TopClipView) alloc] init];
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = YES;  // an editor narrower than the panel
  scroll.autohidesScrollers = YES;
  scroll.drawsBackground = YES;
  scroll.backgroundColor = barColor();
  scroll.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
  scroll.documentView = list;
  [list.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor].active = YES;
  [list.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor].active = YES;
  return scroll;
}

void fitTopBar(NSView* bar, CGFloat width) {
  // The response menu goes first, then the preset menu, then the mode menu.
  NSArray<NSString*>* menus = @[ @"response", @"preset", @"mode" ];
  constexpr CGFloat kNarrowest[] = {520, 400, 230};  // the editor width each needs
  for (NSUInteger i = 0; i < menus.count; ++i) {
    if (NSView* view = findView(bar, menus[i])) view.hidden = width < kNarrowest[i];
  }
}

void showSettings(NSView* root, const settings::Settings& current) {
  showControl(root, current);
  for (NSView* child in root.subviews) showSettings(child, current);
}

std::optional<settings::Settings> readControl(NSControl* control,
                                              const settings::Settings& current) {
  NSString* identifier = control.identifier;
  st::Settings changed = current;
  if ([identifier isEqualToString:@"send"]) {
    changed.setNumber(st::Id::kSendToApp, ((NSButton*)control).state == NSControlStateValueOn);
    return changed;
  }
  if ([identifier isEqualToString:@"response"]) {
    NSNumber* value = ((NSPopUpButton*)control).selectedItem.representedObject;
    if (value == nil) return std::nullopt;
    changed.setNumber(st::Id::kTrailMs, value.doubleValue);
    return changed;
  }
  if ([identifier isEqualToString:@"preset"]) {
    NSString* json = ((NSPopUpButton*)control).selectedItem.representedObject;
    if (json == nil) return std::nullopt;
    st::Report report;
    const auto preset = st::decodePreset(text(json), report);
    if (!preset) return std::nullopt;
    return st::applyPreset(current, preset->settings);
  }
  const auto id = st::find(text(identifier));
  if (!id) return std::nullopt;
  const st::Spec& spec = st::spec(*id);
  switch (spec.type) {
    case st::Type::kBool:
      changed.setNumber(*id, ((NSButton*)control).state == NSControlStateValueOn);
      break;
    case st::Type::kInt:
    case st::Type::kFloat:
      changed.setNumber(*id, fromSlider(spec, control.doubleValue));
      break;
    case st::Type::kChoice: {
      NSString* key = ((NSPopUpButton*)control).selectedItem.representedObject;
      if (key == nil) return std::nullopt;
      changed.setChoice(*id, text(key));
      break;
    }
    case st::Type::kColor: {
      const auto rgba = rgbaOf(((NSColorWell*)control).color);
      if (!rgba) return std::nullopt;
      changed.setNumber(*id, *rgba);
      break;
    }
    case st::Type::kText:
      if ([control isKindOfClass:[NSPopUpButton class]]) {
        NSString* key = ((NSPopUpButton*)control).selectedItem.representedObject;
        if (key == nil) return std::nullopt;
        changed.setText(*id, text(key));
      } else {
        changed.setText(*id, text(control.stringValue));
      }
      break;
  }
  return changed;
}

void refillMenus(NSView* root, const settings::Settings& current) {
  if (NSView* preset = findView(root, @"preset")) fillPresetMenu(((NSPopUpButton*)preset).menu);
  if (NSView* map = findView(root, @"colormap")) {
    fillColormaps((NSPopUpButton*)map, current.text(st::Id::kColormap));
  }
  showSettings(root, current);
}

namespace {

void fillPresetMenu(NSMenu* menu) {
  [menu removeAllItems];
  const auto add = [&](const st::Preset& preset) {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:str(preset.name)
                                                  action:nil
                                           keyEquivalent:@""];
    item.representedObject = str(st::encodePreset(preset));
    [menu addItem:item];
  };
  for (const st::Preset& preset : presets::factory()) add(preset);
  bool separated = false;
  for (const UserFile& file : presets::list(presets::directory())) {
    st::Report report;
    const auto preset = presets::load(file.path, report);
    if (!preset) continue;
    if (!separated) [menu addItem:[NSMenuItem separatorItem]];
    separated = true;
    add(*preset);
  }
  NSMenuItem* custom = [[NSMenuItem alloc] initWithTitle:kCustom action:nil keyEquivalent:@""];
  custom.enabled = NO;
  [menu addItem:custom];
  menu.autoenablesItems = NO;
}

}  // namespace

void showSendState(NSView* dot, InstanceSender::State state) {
  NSColor* color = nil;
  NSString* text = nil;
  switch (state) {
    case InstanceSender::State::kConnected:
      color = [NSColor colorWithSRGBRed:0.35 green:0.82 blue:0.55 alpha:1];
      text = @"Connected";
      break;
    case InstanceSender::State::kNoApp:
      color = [NSColor colorWithSRGBRed:0.95 green:0.70 blue:0.25 alpha:1];
      text = @"App not running";
      break;
    case InstanceSender::State::kUnavailable:
      color = [NSColor colorWithSRGBRed:0.88 green:0.24 blue:0.38 alpha:1];
      text = @"Unavailable in this host";
      break;
    case InstanceSender::State::kOff:
      color = [NSColor colorWithWhite:0.4 alpha:1];
      text = @"Off";
      break;
  }
  dot.layer.backgroundColor = color.CGColor;
  dot.toolTip = text;
  dot.accessibilityElement = YES;
  dot.accessibilityRole = NSAccessibilityImageRole;
  dot.accessibilityLabel = @"Send status";
  dot.accessibilityValue = text;
}

}  // namespace nmr::plugin
