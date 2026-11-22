import AppKit
import NMRCoreC
import os

/// A borderless, transparent, floating window showing the meter fed by the system output.
/// The full overlay (click-through, hover controls, size presets, menu bar) follows in Phase 3.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static let initialSize = NSSize(width: 360, height: 360)
  private var window: NSWindow?
  private var meter: MeterController?
  private let probe: MeterProbe?
  private var probeTimerArmed = false
  private var probeDone = false
  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app", category: "window")

  init(probe: MeterProbe? = nil) {
    self.probe = probe
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = makeMainMenu()

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.initialSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.level = .floating
    window.isMovableByWindowBackground = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    if let meter = MeterController(size: Self.initialSize, settings: Self.firstSettings) {
      meter.view.autoresizingMask = [.width, .height]
      window.contentView = meter.view
      self.meter = meter
      if let probe { arm(probe, meter) }
      meter.startCapture()
    } else {
      Self.log.error("the meter view could not be made (no Metal device)")
    }
    window.center()
    window.makeKeyAndOrderFront(nil)
    self.window = window
    NSApp.activate()
    if let probe, meter == nil { finish(probe) }
  }

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
    let report = MeterProbe.report(meter)
    let code = MeterProbe.write(report, to: probe.outputPath)
    // Still starting: the capture queue may be inside the permission prompt, and stopping would
    // wait for it. Exiting takes the private tap and aggregate down with the process.
    if report.phase != .starting { meter?.stopCapture() }
    exit(code)
  }

  func applicationWillTerminate(_ notification: Notification) {
    meter?.stopCapture()
  }

  /// The NEMURA preset (the original mode) over the defaults.
  private static var firstSettings: SettingValues {
    let base = SettingValues()
    guard let nemura = Presets.factory.first(where: { $0.settings.choice(.mode) == "original" })
    else { return base }
    return base.applying(nemura.settings)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
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
}
