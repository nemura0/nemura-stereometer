import AppKit
import SwiftUI

/// The Settings window (⌘,): dark, resizable, its frame kept between runs. It sits at the normal
/// level, under the floating meter, which shows every change as it is made.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
  static let size = NSSize(width: 720, height: 520)
  static let minimumSize = NSSize(width: 600, height: 420)

  let model: SettingsModel
  private var window: NSWindow?

  init(model: SettingsModel) {
    self.model = model
    super.init()
  }

  var isShown: Bool { window?.isVisible ?? false }

  func show() {
    let window = self.window ?? makeWindow()
    self.window = window
    model.reload()
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    // Activation is a request another app (a DAW in front) may refuse: show the window anyway.
    window.orderFrontRegardless()
  }

  func windowWillClose(_ notification: Notification) {
    window = nil  // made again next time: no hosting view left running while closed
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "Settings"
    window.appearance = NSAppearance(named: .darkAqua)
    window.isReleasedWhenClosed = false
    window.contentMinSize = Self.minimumSize
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
    window.setContentSize(Self.size)
    window.delegate = self
    if !window.setFrameUsingName("Settings") { window.center() }
    window.setFrameAutosaveName("Settings")
    return window
  }
}
