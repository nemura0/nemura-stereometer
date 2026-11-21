import Foundation
import NMRCoreC
import Testing

/// NMR_VERSION as written in config/product.env (the single source of truth).
private func configuredVersion() throws -> String {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let env = try String(contentsOf: root.appending(path: "config/product.env"), encoding: .utf8)
  let line = try #require(env.split(separator: "\n").first { $0.hasPrefix("NMR_VERSION=") })
  return line.dropFirst("NMR_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
}

@Test("The C API reports the version from config/product.env")
func versionMatchesConfig() throws {
  #expect(String(cString: nmr_version()) == (try configuredVersion()))
}

@Test("The C API reports a product name")
func productName() {
  #expect(!String(cString: nmr_product_name()).isEmpty)
}

@Test("The tap probe rejects a missing result pointer without touching Core Audio")
func tapProbeRejectsNullResult() {
  #expect(nmr_tap_probe_run(0, nil) == false)
}
