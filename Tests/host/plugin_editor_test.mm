// The built plugin's editor, opened through clap.gui in a window of the test's: the meter under a
// slim top bar (send toggle and status, mode, preset, response, gear), the settings panel the
// gear opens, and open/close loops that leak nothing. Controls are found by identifier: the bar's
// by name, the panel's by setting key.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#include <doctest/doctest.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <nmr/monotonic_clock.h>
#include <nmr/presets.h>
#include <nmr/settings_json.h>
#include <nmr/shm_transport.h>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <string>

#include "clap_host.h"

using nmr::test::ClapInstance;
using nmr::test::ClapLibrary;
namespace settings = nmr::settings;
namespace shm = nmr::shm;

namespace {

constexpr double kBarHeight = 28;

void spin(double seconds) {
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

NSView* find(NSView* root, NSString* identifier) {
  if ([root.identifier isEqualToString:identifier]) return root;
  for (NSView* child in root.subviews) {
    if (NSView* found = find(child, identifier)) return found;
  }
  return nil;
}

// An editor open in a window, as a host shows it; closed (gui destroy) when this ends.
class EditorSession {
 public:
  explicit EditorSession(ClapInstance& instance, uint32_t width = 600, uint32_t height = 400)
      : instance_(instance), gui_(instance.extension<clap_plugin_gui_t>(CLAP_EXT_GUI)) {
    [NSApplication sharedApplication];
    REQUIRE(gui_ != nullptr);
    window_ = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
                                          styleMask:NSWindowStyleMaskTitled
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    window_.releasedWhenClosed = NO;
    REQUIRE(gui_->create(instance.plugin(), CLAP_WINDOW_API_COCOA, false));
    REQUIRE(gui_->set_size(instance.plugin(), width, height));
    clap_window_t parent{};
    parent.api = CLAP_WINDOW_API_COCOA;
    parent.cocoa = (__bridge void*)window_.contentView;
    REQUIRE(gui_->set_parent(instance.plugin(), &parent));
    REQUIRE(gui_->show(instance.plugin()));
    [window_ orderBack:nil];
    spin(0.05);
  }
  ~EditorSession() {
    if (hide_on_close_) gui_->hide(instance_.plugin());
    gui_->destroy(instance_.plugin());
    [window_ close];
    window_ = nil;
  }
  EditorSession(const EditorSession&) = delete;
  EditorSession& operator=(const EditorSession&) = delete;

  template <typename T = NSView>
  T* control(NSString* identifier) const {
    NSView* view = find(window_.contentView, identifier);
    INFO("no view with identifier " << identifier.UTF8String);
    const bool found = view != nil;
    REQUIRE(found);
    const bool right_kind = [view isKindOfClass:[T class]];
    REQUIRE(right_kind);
    return (T*)view;
  }
  [[nodiscard]] bool has(NSString* identifier) const {
    return find(window_.contentView, identifier) != nil;
  }
  // Closes with gui destroy alone, as some hosts do.
  void destroyWithoutHiding() { hide_on_close_ = false; }
  void resize(uint32_t width, uint32_t height) {
    [window_ setContentSize:NSMakeSize(width, height)];
    REQUIRE(gui_->set_size(instance_.plugin(), width, height));
    spin(0.02);
  }

 private:
  ClapInstance& instance_;
  const clap_plugin_gui_t* gui_;
  NSWindow* window_ = nil;
  bool hide_on_close_ = true;
};

settings::Settings saved(const ClapInstance& instance) {
  std::string state;
  REQUIRE(instance.save(state));
  settings::Report report;
  const settings::Settings decoded = settings::decodeState(state, report);
  REQUIRE(report.status == settings::Status::kOk);
  return decoded;
}

void choose(NSPopUpButton* popup, NSString* title) {
  NSMenuItem* item = [popup itemWithTitle:title];
  INFO("no item " << title.UTF8String);
  const bool found = item != nil;
  REQUIRE(found);
  [popup selectItem:item];
  [popup sendAction:popup.action to:popup.target];
}

void chooseKey(NSPopUpButton* popup, NSString* key) {
  for (NSMenuItem* item in popup.itemArray) {
    if ([item.representedObject isEqual:key]) {
      [popup selectItem:item];
      [popup sendAction:popup.action to:popup.target];
      return;
    }
  }
  FAIL("no item for " << key.UTF8String);
}

NSString* selectedKey(NSPopUpButton* popup) { return popup.selectedItem.representedObject; }

std::unique_ptr<shm::Registry> openRegistry() {
  shm::Status status = shm::Status::kFailed;
  auto registry = shm::Registry::open(ClapLibrary::shared().sendPrefix(), status);
  REQUIRE(registry != nullptr);
  return registry;
}

uint64_t footprint() {
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  REQUIRE(task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info),
                    &count) == KERN_SUCCESS);
  return info.phys_footprint;
}

// The Metal device of a macOS virtual machine ("Apple Paravirtual device").
bool onVirtualGpu() {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  return device == nil || [device.name rangeOfString:@"Paravirtual"].location != NSNotFound;
}

// What the process holds once the allocators gave back what is free and finished frames were
// released: the bytes malloc has handed out and not had back, and the physical footprint (which
// also counts GPU memory). The least of a few samples, since earlier tests leave memory that
// comes and goes meanwhile.
struct Held {
  uint64_t malloc_bytes = UINT64_MAX;
  uint64_t footprint = UINT64_MAX;
};

Held settled() {
  Held least;
  for (int i = 0; i < 5; ++i) {
    spin(0.05);
    malloc_zone_pressure_relief(nullptr, 0);
    malloc_statistics_t stats{};
    malloc_zone_statistics(nullptr, &stats);
    least.malloc_bytes = std::min<uint64_t>(least.malloc_bytes, stats.size_in_use);
    least.footprint = std::min(least.footprint, footprint());
  }
  return least;
}

}  // namespace

TEST_CASE("editor: the meter fills the editor under a slim top bar, at any size") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  EditorSession editor(instance);
  NSView* bar = editor.control(@"topbar");
  NSView* meter = editor.control(@"meter");
  CHECK(bar.frame.size.height == doctest::Approx(kBarHeight));
  CHECK(meter.frame.size.width == doctest::Approx(600));
  CHECK(meter.frame.size.height == doctest::Approx(400 - kBarHeight));
  editor.resize(300, 250);
  CHECK(meter.frame.size.width == doctest::Approx(300));
  CHECK(meter.frame.size.height == doctest::Approx(250 - kBarHeight));
  CHECK(NSMaxY(bar.frame) == doctest::Approx(250));  // the bar stays on top
}

TEST_CASE("editor: the mode menu changes the instance's settings and marks the project changed") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  EditorSession editor(instance);
  auto* mode = editor.control<NSPopUpButton>(@"mode");
  CHECK([selectedKey(mode) isEqualToString:@"original"]);  // a new instance's first look
  const int marks = instance.dirtyMarks();
  chooseKey(mode, @"lissajous");
  CHECK(saved(instance).choiceKey(settings::Id::kMode) == "lissajous");
  CHECK(instance.dirtyMarks() > marks);
}

TEST_CASE("editor: the response menu offers the trail's named stops") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  EditorSession editor(instance);
  auto* response = editor.control<NSPopUpButton>(@"response");
  const auto stops = settings::spec(settings::Id::kTrailMs).stops;
  REQUIRE(!stops.empty());
  choose(response, @(stops.front().label));
  CHECK(saved(instance).number(settings::Id::kTrailMs) == stops.front().value);
}

TEST_CASE("editor: the preset menu applies a factory preset and names the look it matches") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  EditorSession editor(instance);
  auto* preset = editor.control<NSPopUpButton>(@"preset");
  const settings::Preset& classic = nmr::presets::factory()[3];
  choose(preset, @(classic.name.c_str()));
  CHECK(saved(instance) == settings::applyPreset(nmr::presets::firstRun(), classic.settings));
  CHECK([preset.titleOfSelectedItem isEqualToString:@(classic.name.c_str())]);
  chooseKey(editor.control<NSPopUpButton>(@"mode"), @"lissajous");  // no preset looks like it
  CHECK([preset.titleOfSelectedItem isEqualToString:@"Custom"]);
}

TEST_CASE("editor: the send toggle stops and starts sending, and the dot says where it stands") {
  const auto registry = openRegistry();
  ClapInstance instance("Bass");
  REQUIRE(instance.valid());
  REQUIRE(instance.activate());
  EditorSession editor(instance);
  NSView* status = editor.control(@"status");
  spin(0.6);
  CHECK([status.accessibilityValue isEqualToString:@"App not running"]);
  for (int i = 0; i < 6; ++i) {  // the app beats while the dot catches up
    registry->appBeat(nmr::MonotonicClock{}.nowNs(), 4243);
    spin(0.1);
  }
  CHECK([status.accessibilityValue isEqualToString:@"Connected"]);

  auto* send = editor.control<NSButton>(@"send");
  CHECK(send.state == NSControlStateValueOn);
  [send performClick:nil];
  CHECK_FALSE(saved(instance).flag(settings::Id::kSendToApp));
  CHECK(registry->live(nmr::MonotonicClock{}.nowNs()).empty());
  spin(0.6);
  CHECK([status.accessibilityValue isEqualToString:@"Off"]);
  [send performClick:nil];
  CHECK(saved(instance).flag(settings::Id::kSendToApp));
  CHECK(registry->live(nmr::MonotonicClock{}.nowNs()).size() == 1);
  registry->appStopped(4243);
}

TEST_CASE("editor: the gear opens a panel with a control for every setting the plugin uses") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  EditorSession editor(instance);
  CHECK((!editor.has(@"settings") || editor.control(@"settings").hidden));
  auto* gear = editor.control<NSButton>(@"gear");
  [gear performClick:nil];
  NSView* panel = editor.control(@"settings");
  CHECK_FALSE(panel.hidden);
  for (const settings::Spec& spec : settings::schema()) {
    CAPTURE(spec.key);
    CHECK(editor.has(@(spec.key)) == (spec.scope != settings::Scope::kApp));
  }
  [gear performClick:nil];
  CHECK(panel.hidden);
}

TEST_CASE("editor: a change in the panel applies at once and is saved") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  EditorSession editor(instance);
  [editor.control<NSButton>(@"gear") performClick:nil];
  auto* gain = editor.control<NSSlider>(@"gain_db");
  gain.doubleValue = 6;
  [gain sendAction:gain.action to:gain.target];
  CHECK(saved(instance).number(settings::Id::kGainDb) == 6);
  auto* readouts = editor.control<NSButton>(@"meter_readouts");
  const bool before = saved(instance).flag(settings::Id::kMeterReadouts);
  [readouts performClick:nil];
  CHECK(saved(instance).flag(settings::Id::kMeterReadouts) != before);
  auto* name = editor.control<NSTextField>(@"source_name");
  name.stringValue = @"Keys";
  [name sendAction:name.action to:name.target];
  CHECK(saved(instance).text(settings::Id::kSourceName) == "Keys");
}

TEST_CASE("editor: a slider lands on its setting's steps") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  EditorSession editor(instance);
  [editor.control<NSButton>(@"gear") performClick:nil];
  auto* gain = editor.control<NSSlider>(@"gain_db");  // 0.5 dB steps
  gain.doubleValue = 0.137;
  [gain sendAction:gain.action to:gain.target];
  CHECK(saved(instance).number(settings::Id::kGainDb) == 0);
  gain.doubleValue = 3.3;
  [gain sendAction:gain.action to:gain.target];
  CHECK(saved(instance).number(settings::Id::kGainDb) == 3.5);
}

TEST_CASE("editor: a name being typed when the editor closes is kept") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  {
    EditorSession editor(instance);
    editor.destroyWithoutHiding();
    [editor.control<NSButton>(@"gear") performClick:nil];
    auto* name = editor.control<NSTextField>(@"source_name");
    REQUIRE([name.window makeFirstResponder:name]);
    NSText* typing = name.currentEditor;
    const bool editing = typing != nil;
    REQUIRE(editing);
    typing.string = @"Pad";
  }
  CHECK(saved(instance).text(settings::Id::kSourceName) == "Pad");
}

TEST_CASE("editor: an instance destroyed with its editor open leaves nothing running") {
  [NSApplication sharedApplication];
  NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300)
                                                 styleMask:NSWindowStyleMaskTitled
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.releasedWhenClosed = NO;
  {
    ClapInstance instance;
    REQUIRE(instance.valid());
    REQUIRE(instance.activate());
    const auto* gui = instance.extension<clap_plugin_gui_t>(CLAP_EXT_GUI);
    REQUIRE(gui->create(instance.plugin(), CLAP_WINDOW_API_COCOA, false));
    clap_window_t parent{};
    parent.api = CLAP_WINDOW_API_COCOA;
    parent.cocoa = (__bridge void*)window.contentView;
    REQUIRE(gui->set_parent(instance.plugin(), &parent));
    REQUIRE(gui->show(instance.plugin()));
    spin(0.05);
  }  // destroyed without gui destroy, as a crashing host's cleanup might
  spin(0.6);  // the status timer would fire twice here
  CHECK(window.contentView.subviews.count == 0);
  [window close];
}

TEST_CASE("editor: a state loaded while it is open shows in its controls") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  EditorSession editor(instance);
  [editor.control<NSButton>(@"gear") performClick:nil];
  settings::Settings changed = nmr::presets::firstRun();
  changed.setChoice(settings::Id::kMode, "lissajous");
  changed.setNumber(settings::Id::kGainDb, -3);
  changed.setNumber(settings::Id::kSendToApp, 0);
  REQUIRE(instance.load(settings::encodeState(changed)));
  CHECK([selectedKey(editor.control<NSPopUpButton>(@"mode")) isEqualToString:@"lissajous"]);
  CHECK(editor.control<NSSlider>(@"gain_db").doubleValue == -3);
  CHECK(editor.control<NSButton>(@"send").state == NSControlStateValueOff);
}

TEST_CASE("editor: opening and closing it again and again leaks nothing") {
  ClapInstance instance;
  REQUIRE(instance.valid());
  REQUIRE(instance.activate());
  int survivors = 0;  // meters and panels still alive after their editor closed
  const auto cycle = [&](int times) {
    NSPointerArray* closed = [NSPointerArray weakObjectsPointerArray];
    for (int i = 0; i < times; ++i) {
      @autoreleasepool {
        EditorSession editor(instance);
        [editor.control<NSButton>(@"gear") performClick:nil];
        [closed addPointer:(__bridge void*)editor.control(@"meter")];
        [closed addPointer:(__bridge void*)editor.control(@"settings")];
        spin(0.01);
      }
    }
    spin(0.2);
    for (NSUInteger i = 0; i < closed.count; ++i) {  // zeroed when the view went
      if ([closed pointerAtIndex:i] != nullptr) ++survivors;
    }
  };
  // Warm up: caches, the shader library, and Rosetta's translations of the x86_64 slice.
  cycle(25);
  const Held before = settled();
  cycle(50);
  const Held after = settled();
  INFO("malloc " << before.malloc_bytes / 1024 << " KiB -> " << after.malloc_bytes / 1024
                 << " KiB, footprint " << before.footprint / 1024 << " KiB -> "
                 << after.footprint / 1024 << " KiB");
  // Every meter (its layer and drawables with it) and panel goes when its editor closes.
  CHECK(survivors == 0);
  // One editor left behind holds megabytes (its settings panel alone about 5 MiB, its meter's
  // drawables more); free pages the allocator keeps (more under Rosetta) widen the margin.
  CHECK(after.malloc_bytes < before.malloc_bytes + 4 * 1024 * 1024);
  // A virtual GPU (CI's macOS VMs) keeps memory of its own across drawables, which the
  // footprint counts; there the weak references above stand in for it.
  if (!onVirtualGpu()) CHECK(after.footprint < before.footprint + 32 * 1024 * 1024);
}
