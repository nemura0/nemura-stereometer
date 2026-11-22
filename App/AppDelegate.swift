import AppKit
import NMRCoreC
import os

/// Runs the overlay meter (App/Overlay) fed by the system output, or the `--meter-probe`.
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
  private let probe: MeterProbe?
  private var probeTimerArmed = false
  private var probeDone = false
  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app", category: "app")

  init(probe: MeterProbe? = nil) {
    self.probe = probe
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
    if let probe {
      arm(probe, overlay)
      overlay.startCapture(soundSeenBefore: false)
      return
    }
    overlay.onCaptureChange = { [weak self] state in
      self?.menuBar?.model.capture = state
      self?.memory.remember(state)
    }
    if memory.introShown {
      overlay.startCapture(soundSeenBefore: memory.soundSeen)
    } else {
      permission.show(.intro) { [weak self] in
        guard let self else { return }
        self.memory.introShown = true
        self.overlay?.startCapture(soundSeenBefore: self.memory.soundSeen)
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
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
    let report = MeterProbe.report(overlay, menuBar: menuBar)
    let code = MeterProbe.write(report, to: probe.outputPath)
    // Still starting: the capture queue may be inside the permission prompt, and stopping would
    // wait for it. Exiting takes the private tap and aggregate down with the process.
    if report.phase != .starting { overlay?.stop() }
    exit(code)
  }
}
