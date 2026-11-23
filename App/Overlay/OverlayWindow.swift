import AppKit

/// The borderless, transparent meter window. A non-activating panel: clicking or dragging the
/// meter never takes keyboard focus from the app the user works in (a DAW's transport keys).
/// It can be resized from its edges, moved by dragging the meter, filled into the screen (and back)
/// by double-clicking its top edge, and it remembers its frame between launches (kept on a
/// connected screen).
final class OverlayWindow: NSPanel {
  static let minimumSide: CGFloat = 160
  /// The top strip that zooms on a double click: as tall as a title bar.
  static let zoomStripHeight: CGFloat = 28
  private static let frameName = "meter"
  private var restoreFrame: NSRect?

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

  /// Where a double click on the top edge takes a meter at `frame`: one filled before (`restore`
  /// is where it was, even if it moved since) goes back there; one that fills `visible` anyway
  /// goes to the default size, centered; any other fills `visible`.
  static func zoomFrame(for frame: NSRect, restore: NSRect?, in visible: NSRect) -> NSRect {
    if let restore { return restore.fitted(into: visible) }
    guard frame == visible else { return visible }
    let side = MeterSize.medium.side
    return NSRect(
      x: visible.midX - side / 2, y: visible.midY - side / 2, width: side, height: side)
  }

  /// Whether `point` (in the window, from its bottom left) is on the top edge that zooms.
  static func isZoomArea(_ point: NSPoint, in size: NSSize) -> Bool {
    point.y >= size.height - zoomStripHeight && point.y <= size.height
  }

  /// Fills the screen with the meter, or puts it back where it was.
  func toggleFill() {
    guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
    let target = Self.zoomFrame(for: frame, restore: restoreFrame, in: visible)
    restoreFrame = restoreFrame == nil && target == visible ? frame : nil
    setFrame(target, display: true, animate: false)
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown, event.clickCount == 2,
      Self.isZoomArea(event.locationInWindow, in: frame.size), !isOnControl(event)
    {
      toggleFill()
      return
    }
    super.sendEvent(event)
  }

  private func isOnControl(_ event: NSEvent) -> Bool {
    guard let content = contentView, let parent = content.superview else { return false }
    return content.hitTest(parent.convert(event.locationInWindow, from: nil)) is NSControl
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
