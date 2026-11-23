import AppKit
import Testing

@testable import App

/// Double-clicking the meter's top edge fills the screen with it, and again puts it back.
@MainActor
@Suite("Maximizing the meter")
struct MeterZoomTests {
  private let visible = NSRect(x: 0, y: 0, width: 1512, height: 949)

  @Test("A meter that does not fill the screen fills it; one that does goes back")
  func zoomFrames() {
    let small = NSRect(x: 400, y: 300, width: 360, height: 360)
    #expect(OverlayWindow.zoomFrame(for: small, restore: nil, in: visible) == visible)
    #expect(OverlayWindow.zoomFrame(for: visible, restore: small, in: visible) == small)
  }

  @Test("Filling the screen with nothing to go back to, it goes back to the default size")
  func zoomOutWithoutRestore() {
    let full = NSRect(x: 4, y: 0, width: 1508, height: 949)  // nearly full, from a resize
    let filled = OverlayWindow.zoomFrame(for: full, restore: nil, in: visible)
    #expect(filled == visible)
    let back = OverlayWindow.zoomFrame(for: filled, restore: nil, in: visible)
    #expect(back.size == NSSize(width: MeterSize.medium.side, height: MeterSize.medium.side))
    #expect(back.midX == visible.midX)
    #expect(back.midY == visible.midY)
  }

  @Test("Only the top edge zooms: a strip as tall as a title bar")
  func topEdge() {
    let size = NSSize(width: 360, height: 360)
    #expect(OverlayWindow.isZoomArea(NSPoint(x: 180, y: 350), in: size))
    #expect(!OverlayWindow.isZoomArea(NSPoint(x: 180, y: 200), in: size))
  }

  @Test("A double click on the top edge fills the screen; another puts the meter back")
  func doubleClick() throws {
    let meter = OverlayWindow(size: NSSize(width: 360, height: 360), remembersFrame: false)
    meter.orderFrontRegardless()
    defer { meter.close() }
    let screen = try #require(meter.screen?.visibleFrame)
    let before = meter.frame
    meter.sendEvent(try doubleClick(at: NSPoint(x: 180, y: 352), in: meter))
    #expect(meter.frame == screen)
    meter.sendEvent(try doubleClick(at: NSPoint(x: 180, y: screen.height - 8), in: meter))
    #expect(meter.frame == before)
    meter.sendEvent(try doubleClick(at: NSPoint(x: 180, y: 100), in: meter))  // not the top
    #expect(meter.frame == before)
    // Filled, then moved a little: a double click still puts it back where it was.
    meter.sendEvent(try doubleClick(at: NSPoint(x: 180, y: 352), in: meter))
    meter.setFrameOrigin(NSPoint(x: meter.frame.minX + 10, y: meter.frame.minY))
    let top = meter.frame.height - 8
    meter.sendEvent(try doubleClick(at: NSPoint(x: 180, y: top), in: meter))
    #expect(meter.frame == before)
  }

  @Test("A double click on a button in the top edge is the button's, not a zoom")
  func buttonsKeepTheirClicks() throws {
    let meter = OverlayWindow(size: NSSize(width: 360, height: 360), remembersFrame: false)
    let button = ClickCounter(frame: NSRect(x: 8, y: 336, width: 20, height: 20))
    meter.contentView?.addSubview(button)
    meter.orderFrontRegardless()
    defer { meter.close() }
    let before = meter.frame
    meter.sendEvent(try doubleClick(at: NSPoint(x: 18, y: 346), in: meter))
    #expect(meter.frame == before)
    #expect(button.clicks == 1)
  }

  private func doubleClick(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2,
        pressure: 1))
  }
}

/// A control that counts its clicks and returns at once (a button would track until mouse up).
private final class ClickCounter: NSControl {
  var clicks = 0
  override func mouseDown(with event: NSEvent) { clicks += 1 }
}
