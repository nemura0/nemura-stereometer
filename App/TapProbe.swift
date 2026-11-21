import Foundation
import NMRCoreC

/// `--tap-probe`: captures the system output through a process tap for a few seconds and writes
/// a JSON report. Used to check that the audio-capture permission is granted: a denied grant
/// starts the tap normally but delivers only zeros.
enum TapProbe {
  static let defaultSeconds = 4.0

  struct Report: Codable {
    let started: Bool
    let status: Int32
    let failedStep: String
    let startSeconds: Double
    let sampleRate: Double
    let channels: UInt32
    let interleaved: Bool
    let ioCycles: UInt64
    let skippedCycles: UInt64
    let frames: UInt64
    let nonzeroFrames: UInt64
    let lappedFrames: UInt64
    let nonfiniteSamples: UInt64
    let peak: Float
    let rms: Float
    let version: String
    let bundlePath: String
  }

  /// Returns the process exit code: 0 if the tap started, 1 if it did not, 2 if the report
  /// could not be written.
  static func run(seconds: Double, outputPath: String?) -> Int32 {
    var result = nmr_tap_probe_result()
    let started = nmr_tap_probe_run(seconds, &result)
    let report = Report(
      started: started,
      status: result.status,
      failedStep: result.failed_step.map { String(cString: $0) } ?? "",
      startSeconds: result.start_seconds,
      sampleRate: result.sample_rate,
      channels: result.channels,
      interleaved: result.interleaved,
      ioCycles: result.io_cycles,
      skippedCycles: result.skipped_cycles,
      frames: result.frames,
      nonzeroFrames: result.nonzero_frames,
      lappedFrames: result.lapped_frames,
      nonfiniteSamples: result.nonfinite_samples,
      peak: result.peak,
      rms: result.rms,
      version: String(cString: nmr_version()),
      bundlePath: Bundle.main.bundlePath
    )
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
      FileHandle.standardError.write(Data("tap probe: \(error)\n".utf8))
      return 2
    }
    return started ? 0 : 1
  }
}
