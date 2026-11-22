import AppKit

/// The borderless, transparent meter window. A non-activating panel: clicking or dragging the
/// meter never takes keyboard focus from the app the user works in (a DAW's transport keys).
/// It can be resized from its edges, moved by dragging the meter, and it remembers its frame
/// between launches (kept on a connected screen).
final class OverlayWindow: NSPanel {
  static let minimumSide: CGFloat = 160
  private static let frameName = "meter"

  /// `remembersFrame`: restore and save the frame between launches (off in tests).
  init(size: NSSize, remembersFrame: Bool = true) {
    super.init(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovableByWindowBackground = true
    isReleasedWhenClosed = false
    hidesOnDeactivate = false  // panels hide with their app by default; the meter must not
    becomesKeyOnlyIfNeeded = true
    minSize = NSSize(width: Self.minimumSide, height: Self.minimumSide)
    center()
    if remembersFrame { setFrameAutosaveName(Self.frameName) }
    keepOnScreen()
  }

  func apply(_ style: OverlayStyle) {
    level = style.level
    ignoresMouseEvents = style.ignoresMouseEvents
    collectionBehavior = style.collectionBehavior
  }

  func resize(to size: MeterSize) {
    setFrame(onScreen(size.frame(around: frame)), display: true, animate: true)
  }

  /// Back onto the screen it is on (or the main screen when its screen is gone).
  func keepOnScreen() {
    let fitted = onScreen(frame)
    if fitted != frame { setFrame(fitted, display: true) }
  }

  /// Runs `body` with frame saving off: a probe's resizes do not touch the saved frame.
  func withoutSavingFrame(_ body: () -> Void) {
    let name = frameAutosaveName
    setFrameAutosaveName("")
    body()
    if !name.isEmpty { setFrameAutosaveName(name) }
  }

  private func onScreen(_ rect: NSRect) -> NSRect {
    let screen = NSScreen.screens.first { $0.visibleFrame.intersects(rect) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return rect }
    return rect.fitted(into: visible)
  }
}
