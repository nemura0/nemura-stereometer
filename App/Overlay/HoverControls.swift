import AppKit

/// Close, minimize and settings buttons that fade in at the meter's top-left corner while the
/// pointer is over the window, and fade out when it leaves.
@MainActor
final class HoverControls: NSView {
  enum Control: CaseIterable {
    case close, minimize, settings

    var symbol: String {
      switch self {
      case .close: "xmark"
      case .minimize: "minus"
      case .settings: "gearshape.fill"
      }
    }

    var label: String {
      switch self {
      case .close: "Hide"
      case .minimize: "Minimize"
      case .settings: "Quick settings"
      }
    }
  }

  static let buttonSide: CGFloat = 22
  static let spacing: CGFloat = 8
  static let inset: CGFloat = 10
  private static let fade: TimeInterval = 0.18

  var onControl: ((Control, NSView) -> Void)?
  /// False keeps the controls hidden (the setting is off, or click-through is on).
  var isEnabled = true {
    didSet { if !isEnabled { setShown(false, animated: false) } }
  }

  private var buttons: [HoverButton] = []

  init() {
    let count = CGFloat(Control.allCases.count)
    let width = count * Self.buttonSide + (count - 1) * Self.spacing
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.buttonSide))
    for (index, control) in Control.allCases.enumerated() {
      let button = HoverButton(control: control, side: Self.buttonSide)
      button.frame.origin.x = CGFloat(index) * (Self.buttonSide + Self.spacing)
      button.target = self
      button.action = #selector(pressed(_:))
      addSubview(button)
      buttons.append(button)
    }
    alphaValue = 0
    isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  func setShown(_ shown: Bool, animated: Bool = true) {
    let show = shown && isEnabled
    if show { isHidden = false } else { buttons.forEach { $0.resetHover() } }
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    guard animated, !reduceMotion else {
      alphaValue = show ? 1 : 0
      isHidden = !show
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fade
      animator().alphaValue = show ? 1 : 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.alphaValue == 0 else { return }
        self.isHidden = true
      }
    }
  }

  @objc private func pressed(_ sender: HoverButton) {
    onControl?(sender.control, sender)
  }
}

/// One round control: a dark translucent disc that turns Iris (#8993FF) under the pointer.
@MainActor
private final class HoverButton: NSButton {
  let control: HoverControls.Control
  private static let rest = NSColor(white: 0.05, alpha: 0.62)
  private static let hover = NSColor(srgbRed: 0x89 / 255, green: 0x93 / 255, blue: 1, alpha: 0.95)

  init(control: HoverControls.Control, side: CGFloat) {
    self.control = control
    super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
    isBordered = false
    title = ""
    let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.45, weight: .bold)
    image = NSImage(systemSymbolName: control.symbol, accessibilityDescription: control.label)?
      .withSymbolConfiguration(configuration)
    imagePosition = .imageOnly
    contentTintColor = NSColor(white: 1, alpha: 0.9)
    toolTip = control.label
    setAccessibilityLabel(control.label)
    wantsLayer = true
    layer?.cornerRadius = side / 2
    layer?.backgroundColor = Self.rest.cgColor
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  override func mouseEntered(with event: NSEvent) { setHovered(true) }
  override func mouseExited(with event: NSEvent) { setHovered(false) }

  // The window moves when the meter is dragged; a press on a control must not.
  override var mouseDownCanMoveWindow: Bool { false }
  // The panel is rarely key: the first click is the press.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override var isHighlighted: Bool {
    didSet { layer?.opacity = isHighlighted ? 0.7 : 1 }
  }

  func resetHover() { setHovered(false) }

  private func setHovered(_ on: Bool) {
    layer?.backgroundColor = (on ? Self.hover : Self.rest).cgColor
    contentTintColor = on ? .black : NSColor(white: 1, alpha: 0.9)
  }
}
