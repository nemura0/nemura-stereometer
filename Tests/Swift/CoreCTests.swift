import Foundation
import NMRCoreC
import Testing

@Test("The C API reports the version from config/product.env")
func versionMatchesConfig() throws {
  #expect(String(cString: nmr_version()) == (try configuredValue("NMR_VERSION")))
}

@Test("The C API reports a product name")
func productName() {
  #expect(!String(cString: nmr_product_name()).isEmpty)
}

@Test("The tap probe rejects a missing result pointer without touching Core Audio")
func tapProbeRejectsNullResult() {
  #expect(nmr_tap_probe_run(0, nil) == false)
}
