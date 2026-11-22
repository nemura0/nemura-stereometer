import AppKit
import NMRCoreC
import SwiftUI

/// The menu-bar icon (always there, Dock icon or not) and its popover.
@MainActor
final class MenuBarController: NSObject {
  let model: MeterMenuModel
  let popover = NSPopover()
  /// The popover's Settings… button; hidden while nil.
  var onShowSettings: (() -> Void)? {
    didSet { updateContent() }
  }

  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let thumbnails = ModeThumbnails()

  init(model: MeterMenuModel) {
    self.model = model
    super.init()
    if let button = statusItem.button {
      button.image = MenuBarIcon.image
      button.target = self
      button.action = #selector(toggle(_:))
      button.toolTip = String(cString: nmr_product_name())
    }
    popover.behavior = .transient
    popover.appearance = NSAppearance(named: .darkAqua)
    updateContent()
  }

  var isIconShown: Bool { statusItem.isVisible && statusItem.button?.image != nil }

  /// Opens the popover under the icon, or closes it.
  func toggle() {
    if popover.isShown {
      popover.performClose(nil)
      return
    }
    guard let button = statusItem.button else { return }
    model.reloadPresets()
    NSApp.activate()  // the popover takes the keyboard (its slider and toggles)
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
  }

  @objc private func toggle(_ sender: Any?) { toggle() }

  private func updateContent() {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let view = MeterMenuView(
      model: model, thumbnails: thumbnails, scale: Double(scale),
      showSettings: onShowSettings.map { show in
        { [weak self] in
          self?.popover.performClose(nil)
          show()
        }
      },
      quit: { NSApp.terminate(nil) })
    popover.contentViewController = NSHostingController(rootView: view)
  }
}

/// The menu-bar icon: a scope's circle around a slanted trace, drawn as a template image so the
/// menu bar tints it.
enum MenuBarIcon {
  static let side: CGFloat = 18

  static let image: NSImage = {
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      NSColor.black.set()
      let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.6, dy: 1.6))
      ring.lineWidth = 1.4
      ring.stroke()
      let trace = NSBezierPath(
        ovalIn: NSRect(x: rect.midX - 1.6, y: rect.midY - 5, width: 3.2, height: 10))
      var tilt = AffineTransform(translationByX: rect.midX, byY: rect.midY)
      tilt.rotate(byDegrees: -18)
      tilt.translate(x: -rect.midX, y: -rect.midY)
      trace.transform(using: tilt)
      trace.fill()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = String(cString: nmr_product_name())
    return image
  }()
}
