import AppKit
import Testing

@testable import App

/// Settings open docked to the meter: over it in the window order, at its edge, moving with it.
@MainActor
@Suite("Settings docked to the meter")
struct SettingsDockTests {
  private let visible = NSRect(x: 0, y: 0, width: 1512, height: 949)
  private let size = NSSize(width: 640, height: 460)

  @Test("Settings dock under the meter, centered on it, when there is room below")
  func docksBelow() {
    let meter = NSRect(x: 400, y: 500, width: 360, height: 360)
    let frame = SettingsWindow.dockedFrame(for: size, at: meter, in: visible)
    #expect(frame.size == size)
    #expect(frame.maxY == meter.minY)
    #expect(frame.midX == meter.midX)
  }

  @Test("Without room below they dock above; without either, over the meter's lower part")
  func docksAboveOrOver() {
    let low = NSRect(x: 400, y: 100, width: 360, height: 360)
    #expect(SettingsWindow.dockedFrame(for: size, at: low, in: visible).minY == low.maxY)
    let tall = NSRect(x: 400, y: 200, width: 360, height: 700)
    let over = SettingsWindow.dockedFrame(for: size, at: tall, in: visible)
    #expect(visible.contains(over))
    #expect(over.minY == tall.minY)  // over the meter's lower part, bottoms aligned
  }

  @Test("Near the screen's side they stay on it")
  func staysOnScreen() {
    let meter = NSRect(x: 0, y: 500, width: 240, height: 240)
    let frame = SettingsWindow.dockedFrame(for: size, at: meter, in: visible)
    #expect(frame.minX == visible.minX)
    #expect(frame.maxY == meter.minY)
  }

  @Test("They open over the meter, attached to it: in front, at its level, moving with it")
  func attached() throws {
    let meter = OverlayWindow(size: NSSize(width: 360, height: 360), remembersFrame: false)
    meter.level = .floating
    meter.setFrameOrigin(NSPoint(x: 400, y: 500))
    meter.orderFrontRegardless()
    defer { meter.close() }
    let settings = SettingsWindow(model: SettingsModel(store: SettingsStore(defaults: nil)))
    settings.show(attachedTo: meter)
    defer { settings.close() }
    let panel = try #require(settings.shownWindow)
    #expect(meter.childWindows?.contains(panel) == true)
    #expect(panel.level == meter.level)
    #expect(panel.isVisible)
    #expect(panel.frame.maxY == meter.frame.minY)
    #expect(panel.frame.midX == meter.frame.midX)

    let before = panel.frame.origin
    meter.setFrameOrigin(NSPoint(x: meter.frame.minX + 50, y: meter.frame.minY + 20))
    #expect(panel.frame.origin == NSPoint(x: before.x + 50, y: before.y + 20))

    meter.level = .normal  // always on top turned off
    settings.follow()
    #expect(panel.level == .normal)

    settings.close()
    #expect(meter.childWindows?.isEmpty ?? true)
    #expect(settings.shownWindow == nil)
  }

  @Test("With the meter hidden they open on their own")
  func standalone() throws {
    let meter = OverlayWindow(size: NSSize(width: 360, height: 360), remembersFrame: false)
    defer { meter.close() }
    let settings = SettingsWindow(model: SettingsModel(store: SettingsStore(defaults: nil)))
    settings.show(attachedTo: meter)  // never ordered front
    defer { settings.close() }
    let panel = try #require(settings.shownWindow)
    #expect(panel.parent == nil)
    #expect(panel.isVisible)
  }
}
