import AppKit
import Testing

@testable import App

/// The overlay window's behaviour from the window settings, its size presets and hotkeys.
@Suite("Overlay")
@MainActor
struct OverlayTests {
  @Test("Defaults: floating, takes clicks, on every Space and over full-screen apps, no Dock icon")
  func defaults() {
    let style = OverlayStyle(SettingValues())
    #expect(style.level == .floating)
    #expect(!style.ignoresMouseEvents)
    #expect(style.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(style.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(style.showsHoverControls)
    #expect(style.activationPolicy == .accessory)
  }

  @Test("Each window setting changes its own part of the style")
  func eachSetting() throws {
    var settings = SettingValues()
    #expect(settings.set(.alwaysOnTop, to: 0) == .set)
    #expect(OverlayStyle(settings).level == .normal)

    settings = SettingValues()
    #expect(settings.set(.allSpaces, to: 0) == .set)
    let single = OverlayStyle(settings).collectionBehavior
    #expect(!single.contains(.canJoinAllSpaces))
    #expect(single.contains(.fullScreenAuxiliary))

    settings = SettingValues()
    #expect(settings.set(.dockIcon, to: 1) == .set)
    #expect(OverlayStyle(settings).activationPolicy == .regular)

    settings = SettingValues()
    #expect(settings.set(.hoverControls, to: 0) == .set)
    #expect(!OverlayStyle(settings).showsHoverControls)
  }

  @Test("Click-through lets clicks pass and hides the hover controls")
  func clickThrough() {
    var settings = SettingValues()
    #expect(settings.set(.clickThrough, to: 1) == .set)
    let style = OverlayStyle(settings)
    #expect(style.ignoresMouseEvents)
    #expect(!style.showsHoverControls)
  }

  @Test("Size presets are square, growing, and resize around the window's center")
  func sizes() {
    let sides = MeterSize.allCases.map(\.side)
    #expect(sides == sides.sorted())
    #expect(Set(sides).count == sides.count)
    #expect(MeterSize.medium.side == 360)
    let frame = NSRect(x: 100, y: 200, width: 300, height: 200)
    let resized = MeterSize.large.frame(around: frame)
    #expect(resized.width == MeterSize.large.side && resized.height == MeterSize.large.side)
    #expect(resized.midX == frame.midX && resized.midY == frame.midY)
  }

  @Test("The preset that matches a window size, if any")
  func matchingSize() {
    #expect(MeterSize(matching: NSSize(width: 540, height: 540)) == .large)
    #expect(MeterSize(matching: NSSize(width: 540, height: 400)) == nil)
  }

  @Test("A frame past a screen edge moves back inside it, keeping its size")
  func fitsOnScreen() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let past = NSRect(x: 1300, y: -50, width: 360, height: 360)
    #expect(past.fitted(into: screen) == NSRect(x: 1080, y: 0, width: 360, height: 360))
    let inside = NSRect(x: 100, y: 100, width: 360, height: 360)
    #expect(inside.fitted(into: screen) == inside)
  }

  @Test("A frame larger than the screen shrinks to it")
  func shrinksToScreen() {
    let screen = NSRect(x: 0, y: 25, width: 600, height: 500)
    let big = NSRect(x: -10, y: 0, width: 720, height: 720)
    #expect(big.fitted(into: screen) == NSRect(x: 0, y: 25, width: 600, height: 500))
  }

  @Test("Opening the app again brings back a meter that was hidden")
  func reopenShowsHidden() throws {
    let overlay = try #require(OverlayController(settings: SettingValues()))
    defer { overlay.stop() }
    overlay.window.withoutSavingFrame {
      overlay.toggleShown()  // shown
      #expect(overlay.window.isVisible)
      overlay.toggleShown()  // hidden, as the close button does
      #expect(!overlay.window.isVisible)
      overlay.reveal()
      #expect(overlay.window.isVisible)
      overlay.window.orderOut(nil)
    }
  }

  @Test("Without a Dock icon, minimize hides the window (there is no Dock tile to go to)")
  func minimizeWithoutDock() {
    #expect(OverlayStyle(SettingValues()).minimizes == false)
    var settings = SettingValues()
    #expect(settings.set(.dockIcon, to: 1) == .set)
    #expect(OverlayStyle(settings).minimizes)
  }

  @Test("Applying the style sets the window's properties")
  func apply() {
    var settings = SettingValues()
    #expect(settings.set(.clickThrough, to: 1) == .set)
    #expect(settings.set(.alwaysOnTop, to: 0) == .set)
    let window = OverlayWindow(size: NSSize(width: 200, height: 200), remembersFrame: false)
    window.apply(OverlayStyle(settings))
    #expect(window.ignoresMouseEvents)
    #expect(window.level == .normal)
    #expect(!window.hidesOnDeactivate)
    #expect(window.styleMask.contains(.nonactivatingPanel))
  }

  @Test("Each hotkey has its own key, all with ⌃⌥⌘")
  func hotKeyActions() {
    let codes = HotKeys.Action.allCases.map(\.keyCode)
    #expect(Set(codes).count == codes.count)
    #expect(HotKeys.Action.menuModifiers == [.control, .option, .command])
  }
}
