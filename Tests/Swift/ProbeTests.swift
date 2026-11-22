import Foundation
import NMRCoreC
import Testing

@testable import App

/// The debug probes' options and reports.
@Suite("Probes")
struct ProbeTests {
  @Test("Probe seconds: absent gives the default, a valid value is used")
  func secondsValid() {
    let none = Arguments(["app", "--meter-probe"])
    #expect(none.seconds(after: "--meter-probe", default: 4) == .success(4))
    let given = Arguments(["app", "--meter-probe", "2.5", "--out", "x.json"])
    #expect(given.seconds(after: "--meter-probe", default: 4) == .success(2.5))
  }

  @Test(
    "Probe seconds: not a number, out of range or not finite is an error",
    arguments: ["abc", "0", "0.5", "-1", "601", "nan", "inf"])
  func secondsInvalid(value: String) {
    let arguments = Arguments(["app", "--tap-probe", value])
    #expect(arguments.seconds(after: "--tap-probe", default: 4) == .failure(.invalid(value)))
  }

  @Test("The report's phase comes from the capture state, not from its step text")
  func reportPhase() {
    var failed = CaptureState()
    failed.phase = .failed(step: "", status: -50)
    #expect(MeterProbe.Report.Phase(failed.phase) == .failed)
    #expect(MeterProbe.Report.Phase(CaptureState().phase) == .starting)
    #expect(
      MeterProbe.Report.Phase(.capturing(sampleRate: 48_000, channels: 2)) == .capturing)
  }
}
