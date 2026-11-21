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
