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

  @Test("The frames report carries the view's frame statistics")
  func framesReport() {
    let stats = nmr_frame_stats(
      frames: 7200, presented: 7199, dropped: 1, intervals: 7198, period_ms: 8.333,
      p1_ms: 8.125, p50_ms: 8.325, p99_ms: 8.575, max_ms: 16.7, worked: 7190, over_period: 2,
      cpu_p99_ms: 0.4, cpu_max_ms: 1.2, gpu_p99_ms: 1.1, gpu_max_ms: 3.5)
    let report = MeterProbe.FramesReport(stats)
    #expect(report.frames == 7200)
    #expect(report.presented == 7199)
    #expect(report.dropped == 1)
    #expect(report.intervals == 7198)
    #expect(report.periodMs == 8.333)
    #expect(report.p1Ms == 8.125)
    #expect(report.p50Ms == 8.325)
    #expect(report.p99Ms == 8.575)
    #expect(report.maxMs == 16.7)
    #expect(report.worked == 7190)
    #expect(report.overPeriod == 2)
    #expect(report.cpuP99Ms == 0.4)
    #expect(report.cpuMaxMs == 1.2)
    #expect(report.gpuP99Ms == 1.1)
    #expect(report.gpuMaxMs == 3.5)
  }

  @Test("--perf needs --meter-probe and --feed")
  func perfNeedsFeed() {
    #expect(MeterProbe.perfProblem(Arguments(["app", "--meter-probe", "--perf"])) != nil)
    #expect(MeterProbe.perfProblem(Arguments(["app", "--perf", "--feed", "a.wav"])) != nil)
    #expect(
      MeterProbe.perfProblem(Arguments(["app", "--meter-probe", "--perf", "--feed", "a.wav"]))
        == nil)
    #expect(MeterProbe.perfProblem(Arguments(["app", "--meter-probe"])) == nil)
  }
}
