import AppKit
import SwiftUI

/// The Settings panel (⌘,), docked to the meter: a child window of the meter's, in front of it
/// at its level, at its lower edge (its upper one when there is no room below, over its lower
/// part when there is room on neither side), and moving with it, so the meter shows every change
/// as it is made and the panel is never behind it. With the meter hidden it opens on its own.
/// Dark and resizable; it is made again each time it opens.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
  static let size = NSSize(width: 640, height: 460)
  static let minimumSize = NSSize(width: 600, height: 420)

  let model: SettingsModel
  private var window: NSWindow?
  private weak var meter: NSWindow?
  private var observers: [NSObjectProtocol] = []

  init(model: SettingsModel) {
    self.model = model
    super.init()
  }

  var isShown: Bool { window?.isVisible ?? false }
  /// The panel while it is open.
  var shownWindow: NSWindow? { window }

  /// Where a panel of `size` docks to a meter at `meter`, on a screen whose visible part is
  /// `visible`: centered under the meter, else above it, else over its lower part; on the screen.
  static func dockedFrame(for size: NSSize, at meter: NSRect, in visible: NSRect) -> NSRect {
    let x = min(max(meter.midX - size.width / 2, visible.minX), visible.maxX - size.width)
    let y: CGFloat
    if meter.minY - size.height >= visible.minY {
      y = meter.minY - size.height
    } else if meter.maxY + size.height <= visible.maxY {
      y = meter.maxY
    } else {
      y = max(visible.minY, min(meter.minY, visible.maxY - size.height))
    }
    return NSRect(origin: NSPoint(x: x, y: y), size: size)
  }

  /// Opens the panel docked to `meter` (on its own when the meter is not on screen).
  func show(attachedTo meter: NSWindow?) {
    let window = self.window ?? makeWindow()
    self.window = window
    model.reload()
    if let meter, meter.isVisible {
      attach(window, to: meter)
    } else {
      detach()
      window.isMovable = true
      if window.parent == nil, !window.isVisible { window.center() }
    }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    // Activation is a request another app (a DAW in front) may refuse: show the panel anyway.
    window.orderFrontRegardless()
  }

  /// Docks the panel again and takes the meter's level and Spaces (after the meter changed them).
  func follow() {
    guard let window, let meter, window.parent === meter else { return }
    window.level = meter.level
    window.collectionBehavior = meter.collectionBehavior
    let visible = (meter.screen ?? NSScreen.main)?.visibleFrame ?? meter.frame
    let frame = Self.dockedFrame(for: window.frame.size, at: meter.frame, in: visible)
    if frame != window.frame { window.setFrame(frame, display: true) }
  }

  func close() {
    window?.close()
  }

  func windowWillClose(_ notification: Notification) {
    detach()
    window = nil  // made again next time: no hosting view left running while closed
  }

  private func attach(_ window: NSWindow, to meter: NSWindow) {
    if window.parent !== meter {
      detach()
      meter.addChildWindow(window, ordered: .above)
      self.meter = meter
      let center = NotificationCenter.default
      for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
        observers.append(
          center.addObserver(forName: name, object: meter, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
          })
      }
    }
    window.isMovable = false  // it moves with the meter
    follow()
  }

  private func detach() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    if let window, let parent = window.parent { parent.removeChildWindow(window) }
    meter = nil
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.size),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "Settings"
    window.appearance = NSAppearance(named: .darkAqua)
    window.isReleasedWhenClosed = false
    window.contentMinSize = Self.minimumSize
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
    window.setContentSize(Self.size)
    window.delegate = self
    return window
  }
}
