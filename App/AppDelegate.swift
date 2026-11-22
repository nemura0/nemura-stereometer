import AppKit
import NMRCoreC
import os

/// Runs the overlay meter (App/Overlay) fed by the system output or a plugin instance
/// (App/Sources), or the `--meter-probe`.
///
/// The first run explains the audio-capture permission before the capture starts (and with it
/// the macOS prompt). The probe never shows that window, writes nothing to the app's defaults,
/// and always watches the signal, so it checks the watch itself.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var overlay: OverlayController?
  private let memory = CaptureMemory()
  private let store: SettingsStore
  private let permission = PermissionWindow()
  private var menuBar: MenuBarController?
  private var settingsWindow: SettingsWindow?
  private var sources: SourceController?
  private let probe: MeterProbe?
  private var probeTimerArmed = false
  private var probeDone = false
  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app", category: "app")

  /// `--feed`: played instead of the system output from the start.
  private let feed: URL?

  init(probe: MeterProbe? = nil, feed: URL? = nil) {
    self.probe = probe
    self.feed = feed
    // The probe starts from the first-run settings and keeps nothing.
    store = SettingsStore(defaults: probe == nil ? .standard : nil)
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = makeMainMenu()
    guard let overlay = OverlayController(settings: store.values) else {
      Self.log.error("the meter view could not be made (no Metal device)")
      if let probe { finish(probe) }
      return
    }
    self.overlay = overlay
    overlay.onSettingsChange = { [weak self] settings in self?.store.replace(settings) }
    store.observe { [weak overlay] settings in overlay?.update(settings) }
    overlay.onShowPermission = { [weak self] in self?.permission.show(.help) }
    overlay.start()
    let menuBar = MenuBarController(model: MeterMenuModel(store: store))
    if !overlay.registeredHotKeys.contains(.toggleClickThrough) {
      menuBar.model.clickThroughShortcut = nil
    }
    self.menuBar = menuBar
    let settingsWindow = SettingsWindow(model: SettingsModel(store: store))
    self.settingsWindow = settingsWindow
    let showSettings: () -> Void = { [weak self] in self?.settingsWindow?.show() }
    menuBar.onShowSettings = showSettings
    overlay.onShowSettings = showSettings
    let sources = SourceController(overlay: overlay, model: menuBar.model, sources: PluginSources())
    self.sources = sources
    menuBar.model.feedFile = feed
    sources.start()
    if let probe {
      if case .instance(let name) = probe.source {
        arm(probe, following: name, sources)
      } else if let feed {
        probeTimerArmed = true
        sources.choose(.file(feed))
        after(probe.seconds) { $0.finish(probe) }
      } else {
        arm(probe, overlay)
        overlay.startCapture(soundSeenBefore: false)
      }
      return
    }
    overlay.onCaptureChange = { [weak self] state in
      self?.menuBar?.model.capture = state
      self?.memory.remember(state)
    }
    overlay.onCaptureWanted = { [weak self] in self?.allowCapture() }
    if let feed {
      sources.choose(.file(feed))  // no capture yet, so no permission window either
      if memory.introShown { allowCapture() }  // System Output starts it when chosen
      return
    }
    allowCapture()
  }

  /// Lets the capture start, after the first-run window explains the permission if it has not
  /// yet (the capture starts at once if System Output is shown).
  private func allowCapture() {
    if memory.introShown {
      overlay?.startCapture(soundSeenBefore: memory.soundSeen)
      return
    }
    permission.show(.intro) { [weak self] in
      guard let self else { return }
      self.memory.introShown = true
      self.overlay?.startCapture(soundSeenBefore: self.memory.soundSeen)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    sources?.stop()
    overlay?.stop()
  }

  // The window hides rather than closes; the app quits from the quick menu.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  // Opening the app again (Finder, Spotlight, the Dock) brings the meter back, clickable.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    overlay?.reveal()
    return false
  }

  private func makeMainMenu() -> NSMenu {
    let appMenu = NSMenu()
    let settings = NSMenuItem(
      title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
    settings.target = self
    appMenu.addItem(settings)
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit \(String(cString: nmr_product_name()))",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    let menu = NSMenu()
    for submenu in [appMenu, Self.editMenu(), Self.windowMenu()] {
      let item = NSMenuItem()
      item.submenu = submenu
      menu.addItem(item)
    }
    return menu
  }

  /// Text fields (a preset's name) get the standard editing keys from here.
  private static func editMenu() -> NSMenu {
    let menu = NSMenu(title: "Edit")
    menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(.separator())
    menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    menu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    return menu
  }

  /// ⌘W closes the Settings window (the meter has no title bar to close).
  private static func windowMenu() -> NSMenu {
    let menu = NSMenu(title: "Window")
    menu.addItem(
      withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    menu.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m")
    return menu
  }

  @objc private func showSettings(_ sender: Any?) {
    settingsWindow?.show()
  }

  // MARK: - Probe

  /// The probe's seconds start at the capture's first report; without one in time (the
  /// permission prompt is still open, say) it reports what it has.
  private func arm(_ probe: MeterProbe, _ overlay: OverlayController) {
    overlay.onCaptureChange = { [weak self] state in
      self?.menuBar?.model.capture = state
      guard let self, !self.probeTimerArmed else { return }
      self.probeTimerArmed = true
      self.after(probe.seconds) { $0.finish(probe) }
    }
    after(probe.seconds + MeterProbe.startAllowance) { delegate in
      if !delegate.probeTimerArmed { delegate.finish(probe) }
    }
  }

  /// The probe follows the first instance named `name` once it is listed; its seconds start
  /// there.
  private func arm(_ probe: MeterProbe, following name: String, _ sources: SourceController) {
    sources.onPoll = { [weak self, weak sources] instances in
      guard let self, let sources, !self.probeTimerArmed,
        let instance = instances.first(where: { $0.name == name })
      else { return }
      self.probeTimerArmed = true
      sources.choose(.instance(instance))
      self.after(probe.seconds) { $0.finish(probe) }
    }
    after(probe.seconds + MeterProbe.instanceAllowance) { delegate in
      if !delegate.probeTimerArmed { delegate.finish(probe) }
    }
  }

  private func after(_ seconds: Double, _ work: @escaping @MainActor (AppDelegate) -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      MainActor.assumeIsolated {
        if let self { work(self) }
      }
    }
  }

  /// Writes the probe's report and quits with its exit code.
  private func finish(_ probe: MeterProbe) {
    guard !probeDone else { return }
    probeDone = true
    let report = MeterProbe.report(overlay, menuBar: menuBar, source: probe.source)
    let code = MeterProbe.write(report, to: probe.outputPath)
    sources?.stop()
    // A capture still starting may be inside the permission prompt, and stopping it would wait
    // for that; exiting takes the private tap and aggregate down with the process. Following a
    // source, there is no capture to wait for.
    if probe.source != nil || report.phase != .starting { overlay?.stop() }
    exit(code)
  }
}
