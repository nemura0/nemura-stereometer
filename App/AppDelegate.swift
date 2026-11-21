import AppKit
import NMRCoreC

/// Phase 0 window: a borderless, transparent, floating window showing the shared renderer.
/// The real overlay (click-through, hover controls, size presets, menu bar) replaces it in Phase 3.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static let initialSize = NSSize(width: 360, height: 360)
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = makeMainMenu()

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.initialSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.level = .floating
    window.isMovableByWindowBackground = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    var transparent: [Float] = [0, 0, 0, 0]
    if let raw = nmr_render_view_create(Self.initialSize.width, Self.initialSize.height, &transparent) {
      let view = Unmanaged<NSView>.fromOpaque(raw).takeRetainedValue()
      view.autoresizingMask = [.width, .height]
      window.contentView = view
    }
    window.center()
    window.makeKeyAndOrderFront(nil)
    self.window = window
    NSApp.activate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  private func makeMainMenu() -> NSMenu {
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Quit \(String(cString: nmr_product_name()))",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    let appItem = NSMenuItem()
    appItem.submenu = appMenu
    let menu = NSMenu()
    menu.addItem(appItem)
    return menu
  }
}
