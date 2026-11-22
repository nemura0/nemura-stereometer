import Foundation
import Testing

/// A value from config/product.env (the single source of truth for names and IDs).
func configuredValue(_ name: String) throws -> String {
  let root = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let env = try String(contentsOf: root.appending(path: "config/product.env"), encoding: .utf8)
  let line = try #require(env.split(separator: "\n").first { $0.hasPrefix("\(name)=") })
  return line.dropFirst(name.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
}

/// A new, empty folder in the temporary directory, removed with its contents afterwards.
final class TemporaryFolder {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appending(
      path: "nmr-swift-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }
}

/// WAV files for the `--feed` tests.
enum TestWAV {
  /// A 32-bit float stereo WAV of `frames` frames of a quiet ramp.
  static func write(to url: URL, frames: Int, rate: UInt32 = 48000) throws {
    func le<T: FixedWidthInteger>(_ value: T) -> Data {
      withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
    var samples = Data()
    for i in 0..<frames {
      let value = Float(i % 100) / 400
      samples += withUnsafeBytes(of: value) { Data($0) } + withUnsafeBytes(of: -value) { Data($0) }
    }
    var data = Data("RIFF".utf8) + le(UInt32(36 + samples.count)) + Data("WAVEfmt ".utf8)
    data += le(UInt32(16)) + le(UInt16(3)) + le(UInt16(2)) + le(rate) + le(rate * 8)
    data += le(UInt16(8)) + le(UInt16(32)) + Data("data".utf8) + le(UInt32(samples.count))
    data += samples
    try data.write(to: url)
  }
}
