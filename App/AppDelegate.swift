import AppKit
import NMRCoreC
import os

/// Runs the overlay meter (App/Overlay) fed by the system output, or the `--meter-probe`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var overlay: OverlayController?
  private let probe: MeterProbe?
  private var probeTimerArmed = false
  private var probeDone = false
  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app", category: "app")

  init(probe: MeterProbe? = nil) {
    self.probe = probe
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = makeMainMenu()
    guard let overlay = OverlayController(settings: Self.firstSettings) else {
      Self.log.error("the meter view could not be made (no Metal device)")
      if let probe { finish(probe) }
      return
    }
    self.overlay = overlay
    if let probe { arm(probe, overlay.meter) }
    overlay.start()
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

  /// The NEMURA preset (the original mode) over the defaults. Click-through always starts off:
  /// a window that ignores the mouse is never the first thing the user sees.
  private static var firstSettings: SettingValues {
    var settings = SettingValues()
    if let nemura = Presets.factory.first(where: { $0.settings.choice(.mode) == "original" }) {
      settings = settings.applying(nemura.settings)
    }
    _ = settings.set(.clickThrough, to: 0)
    return settings
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
  private func arm(_ probe: MeterProbe, _ meter: MeterController) {
    meter.onCaptureChange = { [weak self] _ in
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
    let report = MeterProbe.report(overlay)
    let code = MeterProbe.write(report, to: probe.outputPath)
    // Still starting: the capture queue may be inside the permission prompt, and stopping would
    // wait for it. Exiting takes the private tap and aggregate down with the process.
    if report.phase != .starting { overlay?.stop() }
    exit(code)
  }
}
