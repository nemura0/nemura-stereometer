import Foundation
import NMRCoreC

/// `--meter-probe`: runs the meter window fed by the system output, then writes a JSON report of
/// what the capture said and whether the meter was drawing sound, and quits. The probe's seconds
/// count from the capture's first report (so a slow start or the permission prompt does not eat
/// them); with no report within startAllowance more, it reports what it has.
/// The end-to-end check behind `scripts/capture-probe.sh --meter`.
struct MeterProbe: Sendable {
  static let defaultSeconds = 4.0
  /// Extra time for the capture's first report: the first run waits on the permission prompt.
  static let startAllowance = 30.0

  let seconds: Double
  let outputPath: String?

  struct Report: Encodable {
    enum Phase: String, Encodable {
      case starting, capturing, failed

      init(_ phase: CaptureState.Phase) {
        switch phase {
        case .starting: self = .starting
        case .capturing: self = .capturing
        case .failed: self = .failed
        }
      }
    }

    let phase: Phase
    let capturing: Bool
    let failedStep: String
    let status: Int32
    let sampleRate: Double
    let channels: Int
    let rebuilds: UInt64
    /// "unknown", "sound" or "silence_while_playing" (CaptureState.Signal).
    let signal: String
    /// The message the meter shows about the capture, if any.
    let notice: String?
    let rendering: Bool
    let idle: Bool
    let overlay: OverlayReport?
    let menuBar: MenuBarReport?
    let version: String
  }

  /// The menu-bar icon and its popover, checked inside the running app (the popover is laid out,
  /// not shown: showing it would take the keyboard from the user's app).
  struct MenuBarReport: Encodable {
    let icon: Bool
    let width: Double
    let height: Double
    let preset: String
    /// A mode chosen in the popover reaches the meter (and is chosen back).
    let modeReachesMeter: Bool

    @MainActor
    init(_ menuBar: MenuBarController, overlay: OverlayController) {
      icon = menuBar.isIconShown
      let size = menuBar.popover.contentViewController?.view.fittingSize ?? .zero
      width = size.width
      height = size.height
      let model = menuBar.model
      preset = model.presetTitle
      let mode = model.mode
      model.mode = mode == .lissajous ? .half : .lissajous
      modeReachesMeter = overlay.meter.settings.choice(.mode) == model.mode.rawValue
      model.mode = mode
    }
  }

  /// The overlay window, checked inside the running app: its state, then a resize to a preset
  /// and two click-through toggles, each undone afterwards.
  struct OverlayReport: Encodable {
    let visible: Bool
    let floating: Bool
    let allSpaces: Bool
    let overFullScreen: Bool
    let clickThrough: Bool
    let hoverControls: Bool
    let width: Double
    let height: Double
    let menu: [String]
    let hotKeys: [String]
    let resizes: Bool
    let clickThroughToggles: Bool
    /// A notice, shown at the smallest and the largest preset, lies inside the meter and leaves
    /// the window's size alone.
    let noticeFits: Bool

    @MainActor
    init(_ overlay: OverlayController) {
      let window = overlay.window
      visible = window.isVisible
      floating = window.level == .floating
      allSpaces = window.collectionBehavior.contains(.canJoinAllSpaces)
      overFullScreen = window.collectionBehavior.contains(.fullScreenAuxiliary)
      clickThrough = window.ignoresMouseEvents
      hoverControls = overlay.showsHoverControls
      width = window.frame.width
      height = window.frame.height
      overlay.menuNeedsUpdate(overlay.quickMenu)
      menu = overlay.quickMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
      hotKeys = HotKeys.Action.allCases.filter { overlay.registeredHotKeys.contains($0) }
        .map { "⌃⌥⌘" + $0.keyEquivalent.uppercased() }

      let frame = window.frame
      var resized = NSRect.zero
      window.withoutSavingFrame {  // the user's saved frame stays as it was
        window.resize(to: .large)
        resized = window.frame
        window.setFrame(frame, display: true)
      }
      resizes = MeterSize(matching: resized.size) == .large
        && abs(resized.midX - frame.midX) < 1 && abs(resized.midY - frame.midY) < 1

      noticeFits = Self.noticeFits(overlay)

      overlay.toggle(.clickThrough)
      let on = window.ignoresMouseEvents && !overlay.showsHoverControls
      overlay.toggle(.clickThrough)
      clickThroughToggles = on && !window.ignoresMouseEvents && overlay.showsHoverControls
    }

    @MainActor
    private static func noticeFits(_ overlay: OverlayController) -> Bool {
      let window = overlay.window
      let frame = window.frame
      let shown = overlay.notice
      var fits = true
      window.withoutSavingFrame {
        for size in [MeterSize.small, .extraLarge] {
          window.resize(to: size)
          let notice = overlay.noticeFrame(showing: .failed(step: "AudioDeviceStart", status: -50))
          let bounds = window.contentView?.bounds ?? .zero
          let inset = NoticeView.inset - 0.5
          fits = fits && MeterSize(matching: window.frame.size) == size && notice.height > 0
            && notice.minX >= inset && notice.maxX <= bounds.width - inset
            && notice.minY >= inset && notice.width <= NoticeView.maximumWidth + 0.5
        }
        _ = overlay.noticeFrame(showing: shown)
        window.setFrame(frame, display: true)
      }
      return fits
    }
  }

  /// The report for `overlay` now.
  @MainActor
  static func report(_ overlay: OverlayController?, menuBar: MenuBarController?) -> Report {
    let version = String(cString: nmr_version())
    guard let overlay else {
      return Report(
        phase: .failed, capturing: false, failedStep: "meter view", status: -1, sampleRate: 0,
        channels: 0, rebuilds: 0, signal: "unknown", notice: nil, rendering: false, idle: false,
        overlay: nil, menuBar: nil, version: version)
    }
    let meter = overlay.meter
    var (step, status, rate, channels) = ("", Int32(0), 0.0, 0)
    switch meter.capture.phase {
    case .starting: break
    case .capturing(let sampleRate, let count): (rate, channels) = (sampleRate, count)
    case .failed(let failed, let code): (step, status) = (failed, code)
    }
    let phase = Report.Phase(meter.capture.phase)
    let view = Unmanaged.passUnretained(meter.view).toOpaque()
    return Report(
      phase: phase, capturing: phase == .capturing, failedStep: step, status: status,
      sampleRate: rate, channels: channels, rebuilds: meter.capture.rebuilds,
      signal: Self.name(meter.capture.signal), notice: overlay.notice?.message,
      rendering: nmr_render_view_is_rendering(view), idle: nmr_render_view_is_idle(view),
      overlay: OverlayReport(overlay),
      menuBar: menuBar.map { MenuBarReport($0, overlay: overlay) }, version: version)
  }

  static func name(_ signal: CaptureState.Signal) -> String {
    switch signal {
    case .unknown: "unknown"
    case .sound: "sound"
    case .silenceWhilePlaying: "silence_while_playing"
    }
  }

  /// Writes `report` and returns the app's exit code: 0 drawing sound, 1 capturing but silent or
  /// idle, 2 not capturing, 3 the report could not be written. (`open -W` does not pass the code
  /// on, so scripts/capture-probe.sh reads the report.)
  static func write(_ report: Report, to outputPath: String?) -> Int32 {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    do {
      let data = try encoder.encode(report)
      if let outputPath {
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
      } else {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
      }
    } catch {
      FileHandle.standardError.write(Data("meter probe: \(error)\n".utf8))
      return 3
    }
    if !report.capturing { return 2 }
    return report.rendering && !report.idle ? 0 : 1
  }
}
