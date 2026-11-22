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
    let rendering: Bool
    let idle: Bool
    let version: String
  }

  /// The report for `meter` now.
  @MainActor
  static func report(_ meter: MeterController?) -> Report {
    let version = String(cString: nmr_version())
    guard let meter else {
      return Report(
        phase: .failed, capturing: false, failedStep: "meter view", status: -1, sampleRate: 0,
        channels: 0, rebuilds: 0, rendering: false, idle: false, version: version)
    }
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
      rendering: nmr_render_view_is_rendering(view), idle: nmr_render_view_is_idle(view),
      version: version)
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
