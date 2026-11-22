import AppKit
import NMRCoreC
import os

/// The overlay: the meter window, its hover controls, capture notice and quick menu, and the
/// global hotkeys. Window settings apply at once; the quick menu (right-click) changes them, and
/// the gear opens Settings.
///
/// The window never activates the app (see OverlayWindow). It can always be brought back:
/// ⌃⌥⌘H, or opening the app again (Finder, Spotlight), which also turns click-through off.
@MainActor
final class OverlayController: NSObject, NSMenuDelegate {
  let window: OverlayWindow
  let meter: MeterController
  private(set) var settings: SettingValues
  /// After every settings change made here (the quick menu, the hotkeys).
  var onSettingsChange: ((SettingValues) -> Void)?
  /// After every capture report (MeterController.onCaptureChange).
  var onCaptureChange: ((CaptureState) -> Void)?
  /// The user asked how to turn the audio-capture permission on.
  var onShowPermission: (() -> Void)?
  /// The gear and the quick menu's Settings… item; without it the gear opens the quick menu.
  var onShowSettings: (() -> Void)?
  /// System Output was chosen before the capture may start (the first-run window has not been
  /// through yet): the app explains the permission, then calls startCapture().
  var onCaptureWanted: (() -> Void)?

  private let controls = HoverControls()
  private let noticeView = NoticeView()
  /// What the notice over the meter says now, if anything.
  var notice: CaptureNotice? { noticeView.notice }
  private var soundSeenBefore = false
  /// False while a plugin instance or a file is shown: capture reports and notices do not
  /// apply then.
  private var followsSystemOutput = true
  /// Set by startCapture(): from then on, System Output starts the capture when chosen.
  private var mayCapture = false
  private let hotKeys = HotKeys()
  /// Right-click and the gear; its items are rebuilt each time it opens.
  let quickMenu = NSMenu()
  var showsHoverControls: Bool { controls.isEnabled }
  var registeredHotKeys: Set<HotKeys.Action> { hotKeys.registered }
  private var content: OverlayContentView?
  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app", category: "overlay")

  /// The window settings the quick menu toggles, in menu order.
  private static let menuFlags: [SettingKey] = [
    .alwaysOnTop, .clickThrough, .allSpaces, .hoverControls, .dockIcon,
  ]

  /// Nil when the meter view cannot be made (no Metal device).
  init?(settings: SettingValues) {
    let size = NSSize(square: MeterSize.medium.side)
    guard let meter = MeterController(size: size, settings: settings) else { return nil }
    self.meter = meter
    self.settings = settings
    window = OverlayWindow(size: size)
    super.init()

    let content = OverlayContentView(meter: meter.view, controls: controls, notice: noticeView)
    content.onHover = { [weak self] inside in self?.hovered(inside) }
    window.contentView = content
    self.content = content
    quickMenu.delegate = self
    content.menu = quickMenu
    meter.view.menu = quickMenu
    controls.onControl = { [weak self] control, button in self?.handle(control, from: button) }
    noticeView.onAction = { [weak self] in self?.noticeAction() }
    meter.onCaptureChange = { [weak self] state in self?.captureChanged(state) }
    apply()
  }

  /// Shows the window and starts the hotkeys; the capture starts with startCapture(), after the
  /// first-run window if there is one.
  func start() {
    present()
    let clickThrough = hotKeys.register(.toggleClickThrough) { [weak self] in
      self?.toggle(.clickThrough)
    }
    let shown = hotKeys.register(.toggleShown) { [weak self] in self?.toggleShown() }
    // The quick menu says which shortcut is missing and offers click-through only with its key.
    if !clickThrough || !shown { Self.log.error("a global hotkey is taken by another app") }
  }

  /// Lets the capture start (after the first-run window, if there is one) and starts it,
  /// unless a plugin instance or a file is shown: then it starts when System Output is chosen.
  func startCapture(soundSeenBefore: Bool) {
    self.soundSeenBefore = self.soundSeenBefore || soundSeenBefore
    mayCapture = true
    guard followsSystemOutput else { return }
    meter.startCapture(soundSeenBefore: soundSeenBefore)
  }

  /// Shows `source`: the system output (the capture starts again, or first the first-run
  /// window through onCaptureWanted) or a plugin instance or file (the capture stops, and its
  /// notice goes). Returns how a file plays (nil for the other sources).
  @discardableResult
  func follow(_ source: MeterSource, in sources: PluginSources?) -> FileState? {
    if case .systemOutput = source {
      meter.stopFeed()
      meter.stopFile()
      followsSystemOutput = true
      if mayCapture {
        meter.startCapture(soundSeenBefore: soundSeenBefore || meter.capture.signal == .sound)
      } else {
        onCaptureWanted?()
      }
      return nil
    }
    soundSeenBefore = soundSeenBefore || meter.capture.signal == .sound
    followsSystemOutput = false
    noticeView.show(nil)
    switch source {
    case .instance(let instance):
      if let sources { meter.follow(instance: instance.id, in: sources) }
      return nil
    case .file(let url):
      return meter.play(file: url)
    case .systemOutput:
      return nil
    }
  }

  /// A failed capture, tried again from the start (its notice goes until the new start reports).
  func restartCapture() {
    guard followsSystemOutput else { return }
    let soundSeen = soundSeenBefore || meter.capture.signal == .sound
    meter.stopCapture()
    meter.startCapture(soundSeenBefore: soundSeen)
  }

  /// Opening the app again: shows the window and turns click-through off, so a window the user
  /// cannot click (or cannot find) always comes back.
  func reveal() {
    if settings.flag(.clickThrough) { toggle(.clickThrough) }
    present()
  }

  /// Before quitting.
  func stop() {
    hotKeys.unregisterAll()
    meter.stopFeed()
    meter.stopFile()
    meter.stopCapture()
  }

  /// Settings changed elsewhere (the popover, the Settings window): applied, not reported back.
  func update(_ settings: SettingValues) {
    guard settings != self.settings else { return }
    self.settings = settings
    apply()
  }

  func toggle(_ key: SettingKey) {
    let change = settings.set(key, to: settings.flag(key) ? 0 : 1)
    guard change != .rejected else {
      Self.log.error("the setting \(key.rawValue, privacy: .public) was rejected")
      return
    }
    apply()
    onSettingsChange?(settings)
  }

  func toggleShown() {
    if window.isVisible && !window.isMiniaturized { hide() } else { present() }
  }

  /// In front without activating the app (the user's app keeps the keyboard).
  private func present() {
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.keepOnScreen()
    window.orderFrontRegardless()
  }

  private func hide() {
    hovered(false)
    window.orderOut(nil)
  }

  private func hovered(_ inside: Bool) {
    controls.setShown(inside)
    content?.showsOutline = inside && !settings.flag(.clickThrough)
  }

  private var pointerInside: Bool {
    guard let content, window.isVisible else { return false }
    let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    return content.bounds.contains(point)
  }

  private func apply() {
    meter.apply(settings)
    let style = OverlayStyle(settings)
    window.apply(style)
    controls.isEnabled = style.showsHoverControls
    noticeView.allowsAction = !style.ignoresMouseEvents
    hovered(pointerInside)  // no mouseEntered comes for a pointer already inside
    if NSApp.activationPolicy() != style.activationPolicy {
      if !NSApp.setActivationPolicy(style.activationPolicy) {
        Self.log.error("the Dock icon setting could not be applied")
      } else if style.activationPolicy == .regular {
        NSApp.activate()  // the user asked for the Dock icon: show the app's menu bar with it
      }
    }
  }

  /// For the probe: shows `notice` as a capture report would, and returns its frame in the
  /// window's content view after layout (`.zero` when hidden).
  func noticeFrame(showing notice: CaptureNotice?) -> NSRect {
    noticeView.show(notice)
    window.contentView?.layoutSubtreeIfNeeded()
    return notice == nil ? .zero : noticeView.frame
  }

  private func captureChanged(_ state: CaptureState) {
    if followsSystemOutput { noticeView.show(CaptureNotice(state)) }
    onCaptureChange?(state)
  }

  private func noticeAction() {
    switch noticeView.notice {
    case .failed: restartCapture()
    case .silenceWhilePlaying: onShowPermission?()
    case nil: break
    }
  }

  private func handle(_ control: HoverControls.Control, from button: NSView) {
    switch control {
    case .close: hide()  // ⌃⌥⌘H or opening the app again brings it back
    case .minimize:
      // Without a Dock icon there is no Dock tile to minimize to.
      if OverlayStyle(settings).minimizes { window.miniaturize(nil) } else { hide() }
    case .settings:
      if let onShowSettings {
        onShowSettings()
      } else {
        quickMenu.popUp(
          positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
      }
    }
  }

  // MARK: - Quick menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.autoenablesItems = false
    let sizes = NSMenu()
    let current = MeterSize(matching: window.frame.size)
    for (index, size) in MeterSize.allCases.enumerated() {
      let item = NSMenuItem(
        title: "\(size.label) (\(Int(size.side)) pt)", action: #selector(pickSize(_:)),
        keyEquivalent: "")
      item.target = self
      item.tag = index
      item.state = size == current ? .on : .off
      sizes.addItem(item)
    }
    let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
    sizeItem.submenu = sizes
    menu.addItem(sizeItem)
    menu.addItem(.separator())

    let missing = HotKeys.Action.allCases.filter { !hotKeys.registered.contains($0) }
    for key in Self.menuFlags {
      let item = NSMenuItem(
        title: Schema.spec(key)?.label ?? key.rawValue, action: #selector(toggleFlag(_:)),
        keyEquivalent: key == .clickThrough ? HotKeys.Action.toggleClickThrough.keyEquivalent : "")
      if key == .clickThrough { item.keyEquivalentModifierMask = HotKeys.Action.menuModifiers }
      item.target = self
      item.representedObject = key.rawValue
      item.state = settings.flag(key) ? .on : .off
      // Without its shortcut nothing could turn click-through off again.
      if key == .clickThrough && missing.contains(.toggleClickThrough) && !settings.flag(key) {
        item.isEnabled = false
      }
      menu.addItem(item)
    }
    for action in missing {
      let note = NSMenuItem(
        title: "⌃⌥⌘\(action.keyEquivalent.uppercased()) is in use by another app", action: nil,
        keyEquivalent: "")
      note.isEnabled = false
      menu.addItem(note)
    }
    menu.addItem(.separator())

    if case .failed = noticeView.notice {
      let restart = NSMenuItem(
        title: "Restart Capture", action: #selector(restartFromMenu(_:)), keyEquivalent: "")
      restart.target = self
      menu.addItem(restart)
    }
    if onShowSettings != nil {
      let settings = NSMenuItem(
        title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
      settings.target = self
      menu.addItem(settings)
    }
    let permission = NSMenuItem(
      title: "Audio Permission…", action: #selector(showPermission(_:)), keyEquivalent: "")
    permission.target = self
    menu.addItem(permission)
    menu.addItem(.separator())

    let hide = NSMenuItem(
      title: "Hide", action: #selector(hideWindow(_:)),
      keyEquivalent: HotKeys.Action.toggleShown.keyEquivalent)
    hide.keyEquivalentModifierMask = HotKeys.Action.menuModifiers
    hide.target = self
    menu.addItem(hide)
    menu.addItem(
      NSMenuItem(
        title: "Quit \(String(cString: nmr_product_name()))",
        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
  }

  @objc private func pickSize(_ item: NSMenuItem) {
    guard MeterSize.allCases.indices.contains(item.tag) else { return }
    window.resize(to: MeterSize.allCases[item.tag])
  }

  @objc private func toggleFlag(_ item: NSMenuItem) {
    guard let raw = item.representedObject as? String, let key = SettingKey(rawValue: raw) else {
      return
    }
    toggle(key)
  }

  @objc private func hideWindow(_ item: NSMenuItem) {
    hide()
  }

  @objc private func restartFromMenu(_ item: NSMenuItem) {
    restartCapture()
  }

  @objc private func showSettings(_ item: NSMenuItem) {
    onShowSettings?()
  }

  @objc private func showPermission(_ item: NSMenuItem) {
    onShowPermission?()
  }
}

/// The meter with the hover controls over its top-left corner and the capture notice over its
/// bottom; reports the pointer entering and leaving the window.
@MainActor
private final class OverlayContentView: NSView {
  var onHover: ((Bool) -> Void)?
  private weak var notice: NoticeView?
  /// A faint edge while the pointer is over the window, so its size and edges can be seen.
  var showsOutline = false {
    didSet { layer?.borderWidth = showsOutline ? 1 : 0 }
  }

  init(meter: NSView, controls: HoverControls, notice: NoticeView) {
    super.init(frame: meter.frame)
    autoresizesSubviews = true
    wantsLayer = true
    layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
    layer?.cornerRadius = 6
    meter.frame = bounds
    meter.autoresizingMask = [.width, .height]
    addSubview(meter)
    controls.frame.origin = NSPoint(
      x: HoverControls.inset, y: bounds.height - HoverControls.inset - controls.frame.height)
    controls.autoresizingMask = [.maxXMargin, .minYMargin]
    addSubview(controls)
    self.notice = notice
    notice.place(in: self)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  override func resizeSubviews(withOldSize oldSize: NSSize) {
    super.resizeSubviews(withOldSize: oldSize)
    notice?.placeInSuperview()
  }

  override func mouseEntered(with event: NSEvent) { onHover?(true) }
  override func mouseExited(with event: NSEvent) { onHover?(false) }
}

extension NSSize {
  init(square side: CGFloat) { self.init(width: side, height: side) }
}
