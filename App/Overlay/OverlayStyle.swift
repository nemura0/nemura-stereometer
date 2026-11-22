import AppKit

/// How the overlay window behaves, from the window settings.
struct OverlayStyle: Equatable {
  let level: NSWindow.Level
  /// Click-through: clicks reach the windows below.
  let ignoresMouseEvents: Bool
  let collectionBehavior: NSWindow.CollectionBehavior
  /// Off while click-through is on: the window gets no mouse events to show them with.
  let showsHoverControls: Bool
  let activationPolicy: NSApplication.ActivationPolicy
  /// Minimize goes to the Dock only when the app has a Dock icon; otherwise it hides the window.
  let minimizes: Bool

  init(_ settings: SettingValues) {
    level = settings.flag(.alwaysOnTop) ? .floating : .normal
    ignoresMouseEvents = settings.flag(.clickThrough)
    // Over full-screen apps in either case; on every Space only when asked.
    collectionBehavior = settings.flag(.allSpaces)
      ? [.canJoinAllSpaces, .fullScreenAuxiliary]
      : [.managed, .fullScreenAuxiliary]
    showsHoverControls = settings.flag(.hoverControls) && !ignoresMouseEvents
    activationPolicy = settings.flag(.dockIcon) ? .regular : .accessory
    minimizes = settings.flag(.dockIcon)
  }
}

/// The window's size presets: square, like the goniometer. Free resizing stays available.
enum MeterSize: CaseIterable, Sendable {
  case small, medium, large, extraLarge

  var side: CGFloat {
    switch self {
    case .small: 240
    case .medium: 360
    case .large: 540
    case .extraLarge: 720
    }
  }

  var label: String {
    switch self {
    case .small: "Small"
    case .medium: "Medium"
    case .large: "Large"
    case .extraLarge: "Extra large"
    }
  }

  /// The preset a window of `size` has, if any.
  init?(matching size: NSSize) {
    let square = { (preset: Self) in preset.side == size.width && preset.side == size.height }
    guard let match = Self.allCases.first(where: square) else { return nil }
    self = match
  }

  /// `frame` resized to this preset around its center.
  func frame(around frame: NSRect) -> NSRect {
    NSRect(
      x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
  }
}

extension NSRect {
  /// This frame moved (and, if it is larger, shrunk) to lie inside `visible`.
  func fitted(into visible: NSRect) -> NSRect {
    let width = Swift.min(self.width, visible.width)
    let height = Swift.min(self.height, visible.height)
    let x = Swift.min(Swift.max(minX, visible.minX), visible.maxX - width)
    let y = Swift.min(Swift.max(minY, visible.minY), visible.maxY - height)
    return NSRect(x: x, y: y, width: width, height: height)
  }
}
