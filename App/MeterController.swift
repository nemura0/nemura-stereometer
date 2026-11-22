import AppKit
import NMRCoreC
import os

/// What the system capture last reported.
struct CaptureState: Equatable, Sendable {
  enum Phase: Equatable, Sendable {
    case starting
    case capturing(sampleRate: Double, channels: Int)
    case failed(step: String, status: Int32)
  }

  var phase: Phase = .starting
  var rebuilds: UInt64 = 0

  init() {}

  init(_ status: nmr_capture_status) {
    rebuilds = status.rebuilds
    if status.status == 0 {
      phase = .capturing(sampleRate: status.sample_rate, channels: Int(status.channels))
    } else {
      let step = status.failed_step.map { String(cString: $0) } ?? ""
      phase = .failed(step: step, status: status.status)
    }
  }
}

/// The meter view fed by the system output, with the settings it draws.
///
/// While capturing, the capture's callback holds a reference to the controller, so it lives until
/// stopCapture() (call it before quitting, as the app delegate does).
@MainActor
final class MeterController {
  let view: NSView
  private(set) var settings: SettingValues
  private(set) var capture = CaptureState() {
    didSet { onCaptureChange?(capture) }
  }
  /// Main thread, after every start or rebuild of the capture.
  var onCaptureChange: ((CaptureState) -> Void)?

  private var handle: OpaquePointer?
  private var callbackReference: Unmanaged<MeterController>?
  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app", category: "capture")

  /// Nil when the view could not be made (no Metal device).
  init?(size: NSSize, settings: SettingValues) {
    var transparent: [Float] = [0, 0, 0, 0]
    guard let raw = nmr_render_view_create(size.width, size.height, &transparent) else {
      return nil
    }
    view = Unmanaged<NSView>.fromOpaque(raw).takeRetainedValue()
    self.settings = settings
    apply(settings)
  }

  /// Draws with `settings` from the next frame on (a user colormap is read from its file here).
  func apply(_ settings: SettingValues) {
    self.settings = settings
    let table = Colormaps.table(for: settings.text(.colormap), userFolder: Colormaps.directory)
    let applied = settings.withHandle { settingsHandle in
      table.rgba.withUnsafeBufferPointer { rgba in
        nmr_render_view_apply(viewPointer, settingsHandle, rgba.baseAddress)
      }
    }
    if !applied { Self.log.error("the meter settings could not be applied") }
  }

  /// Starts following the system output (the first start may show the permission prompt).
  /// Calling it again while capturing changes nothing.
  func startCapture() {
    if handle == nil {
      // The callback's reference, released by stopCapture() once no callback can come.
      let reference = Unmanaged.passRetained(self)
      handle = nmr_capture_create(viewPointer, { context, status in
        guard let context, let status else { return }
        let controller = Unmanaged<MeterController>.fromOpaque(context).takeUnretainedValue()
        let state = CaptureState(status.pointee)
        // The capture calls back on the main queue.
        MainActor.assumeIsolated { controller.reported(state) }
      }, reference.toOpaque())
      if handle == nil { reference.release() } else { callbackReference = reference }
    }
    guard let handle else {
      Self.log.error("the system capture could not be set up")
      var failed = CaptureState()
      failed.phase = .failed(step: "capture setup", status: -1)
      capture = failed
      return
    }
    nmr_capture_start(handle)
  }

  /// Stops the capture and waits for it; no callback comes after this returns.
  func stopCapture() {
    guard let handle else { return }
    nmr_capture_stop(handle)
    nmr_capture_destroy(handle)
    self.handle = nil
    callbackReference?.release()
    callbackReference = nil
  }

  private var viewPointer: UnsafeMutableRawPointer {
    Unmanaged.passUnretained(view).toOpaque()
  }

  private func reported(_ state: CaptureState) {
    if case .failed(let step, let status) = state.phase {
      Self.log.error("system capture failed at \(step, privacy: .public): \(status)")
    }
    capture = state
  }
}
