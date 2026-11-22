import AppKit

/// A capture notice over the bottom of the meter: an icon, the whole message and one action
/// below it. Hidden while there is nothing to say.
///
/// Laid out by frames, not constraints: the window's size never depends on it, hidden or shown
/// (the meter window is freely resizable down to OverlayWindow.minimumSide). Its height follows
/// its width, so the message is never cut; the icon goes in narrow windows to leave the text
/// room. The text is not selectable: a click on it never takes the keyboard from the user's app.
@MainActor
final class NoticeView: NSView {
  static let inset: CGFloat = 10
  static let maximumWidth: CGFloat = 420
  private static let padding = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
  private static let iconSide: CGFloat = 14
  private static let iconMinimumWidth: CGFloat = 200  // narrower notices show no icon
  private static let gap: CGFloat = 6
  private static let fade: TimeInterval = 0.18
  private static let iris = NSColor(
    srgbRed: 0x89 / 255, green: 0x93 / 255, blue: 0xFF / 255, alpha: 1)

  var onAction: (() -> Void)?
  private(set) var notice: CaptureNotice?
  /// Off while the window ignores the mouse (click-through): a button that cannot be clicked is
  /// not offered (⌃⌥⌘S makes the window clickable again).
  var allowsAction = true {
    didSet {
      guard allowsAction != oldValue else { return }
      button.isHidden = !showsAction
      placeInSuperview()
    }
  }
  var showsAction: Bool { allowsAction && notice != nil }
  var labelIsSelectable: Bool { label.isSelectable }

  private let icon = NSImageView()
  private let label = NSTextField(wrappingLabelWithString: "")
  private let button = NoticeButton(title: "", target: nil, action: nil)

  init() {
    super.init(frame: .zero)
    appearance = NSAppearance(named: .darkAqua)
    wantsLayer = true
    layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.86).cgColor
    layer?.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
    layer?.borderWidth = 1
    layer?.cornerRadius = 8
    isHidden = true
    alphaValue = 0

    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = NSColor(white: 1, alpha: 0.88)
    label.isSelectable = false
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    button.controlSize = .small
    button.bezelColor = Self.iris
    button.target = self
    button.action = #selector(act(_:))
    for view in [icon, label, button] as [NSView] { addSubview(view) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  /// Adds the notice to `container`; the container calls placeInSuperview() when it resizes.
  func place(in container: NSView) {
    container.addSubview(self)
    placeInSuperview()
  }

  func placeInSuperview() {
    guard let superview else { return }
    frame = Self.frame(for: self, in: superview.bounds)
    needsLayout = true
  }

  /// Where `notice` goes in a container of `bounds`: centered at the bottom, inset from the
  /// edges, at most maximumWidth wide, as tall as its text needs.
  static func frame(for notice: NoticeView, in bounds: NSRect) -> NSRect {
    let width = max(0, min(bounds.width - 2 * inset, maximumWidth))
    return NSRect(
      x: (bounds.midX - width / 2).rounded(), y: bounds.minY + inset, width: width,
      height: notice.height(forWidth: width))
  }

  /// Whether the label shows every line of its message at `width`.
  func labelFitsWithoutTruncation(width: CGFloat) -> Bool {
    label.maximumNumberOfLines == 0 && labelSize(forWidth: width).height.isFinite
  }

  /// Shows `notice`, or hides the view for nil.
  func show(_ notice: CaptureNotice?) {
    guard notice != self.notice else { return }
    self.notice = notice
    if let notice {
      let failed = if case .failed = notice { true } else { false }
      icon.image = NSImage(
        systemSymbolName: failed ? "exclamationmark.triangle.fill" : "speaker.slash.fill",
        accessibilityDescription: nil)
      icon.contentTintColor = failed ? .systemOrange : Self.iris
      label.stringValue = notice.message
      button.title = notice.actionTitle
      setAccessibilityElement(true)
      setAccessibilityRole(.group)
      setAccessibilityLabel(notice.message)
      NSAccessibility.post(
        element: self, notification: .announcementRequested,
        userInfo: [.announcement: notice.message, .priority: NSAccessibilityPriorityLevel.high])
    }
    button.isHidden = !showsAction
    placeInSuperview()
    fade(to: notice != nil)
  }

  override func layout() {
    super.layout()
    let bounds = self.bounds
    let showsIcon = bounds.width >= Self.iconMinimumWidth
    let text = labelSize(forWidth: bounds.width)
    let top = bounds.maxY - Self.padding.top
    let textX = Self.padding.left + (showsIcon ? Self.iconSide + Self.gap : 0)
    icon.isHidden = !showsIcon
    icon.frame = NSRect(
      x: Self.padding.left, y: top - Self.iconSide, width: Self.iconSide, height: Self.iconSide)
    label.frame = NSRect(x: textX, y: top - text.height, width: text.width, height: text.height)
    let size = button.intrinsicContentSize
    button.frame = NSRect(
      x: bounds.maxX - Self.padding.right - size.width, y: Self.padding.bottom,
      width: size.width, height: size.height)
  }

  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private func height(forWidth width: CGFloat) -> CGFloat {
    let text = labelSize(forWidth: width).height
    let action = showsAction ? Self.gap + button.intrinsicContentSize.height : 0
    return (Self.padding.top + max(text, Self.iconSide) + action + Self.padding.bottom).rounded(.up)
  }

  /// The label's size at a notice `width`: the text's width there, and every line of it.
  private func labelSize(forWidth width: CGFloat) -> NSSize {
    let showsIcon = width >= Self.iconMinimumWidth
    let textWidth = max(
      1, width - Self.padding.left - Self.padding.right
        - (showsIcon ? Self.iconSide + Self.gap : 0))
    let needed = label.cell?.cellSize(
      forBounds: NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude))
    return NSSize(width: textWidth, height: (needed?.height ?? 0).rounded(.up))
  }

  @objc private func act(_ sender: NSButton) { onAction?() }

  private func fade(to shown: Bool) {
    if shown { isHidden = false }
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduceMotion ? 0 : Self.fade
      animator().alphaValue = shown ? 1 : 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.notice == nil else { return }
        self.isHidden = true
      }
    }
  }
}

/// A button the first click on an inactive app's window reaches, which never drags the window.
private final class NoticeButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
}
