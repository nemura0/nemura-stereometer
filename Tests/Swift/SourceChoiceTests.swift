import Foundation
import NMRCoreC
import Testing

@testable import App

@MainActor
@Suite("Choosing a source")
struct SourceChoiceTests {
  @Test("An option given without its value is an error, not a silent default")
  func missingValues() {
    let given = Arguments(["app", "--feed", "mix.wav", "--meter-probe"])
    #expect(given.option("--feed") == .success("mix.wav"))
    #expect(given.option("--instance") == .success(nil))
    #expect(Arguments(["app", "--feed"]).option("--feed") == .failure(.missingValue("--feed")))
    #expect(
      Arguments(["app", "--instance", "--meter-probe"]).option("--instance")
        == .failure(.missingValue("--instance")))
  }

  @Test("Instances of the same name in the same app are told apart in the picker")
  func duplicateTitles() {
    let menu = MeterMenuModel(store: SettingsStore(defaults: nil), presetFolder: nil)
    let first = PluginInstance(id: 1, name: "Bass", host: "Live", sampleRate: 48000, channels: 2)
    let second = PluginInstance(id: 2, name: "Bass", host: "Live", sampleRate: 48000, channels: 2)
    let drums = PluginInstance(id: 3, name: "Drums", host: "Live", sampleRate: 48000, channels: 2)
    menu.instances = [first, drums, second]
    #expect(menu.instances.map(menu.title(for:)) == [
      "Bass — Live", "Drums — Live", "Bass — Live (2)",
    ])
    menu.source = .instance(second)
    #expect(menu.sourceTitle == "Bass — Live (2)")
    menu.instances = []  // gone: its own title again
    #expect(menu.sourceTitle == "Bass — Live")
  }

  @Test("A file too long to play, or one that could not be set up, says so")
  func fileProblems() {
    #expect(FileState.Problem(NMR_FEED_TOO_LONG) == .tooLong)
    #expect(FileState.Problem(NMR_FEED_FAILED) == .failed)
    #expect(FileState.Problem.tooLong.description.contains("too long"))
  }

  @Test("A --feed file that cannot play stops the launch with a message saying why")
  func feedFailureAtLaunch() {
    let url = URL(filePath: "/Users/me/tu-archivo.wav")
    #expect(
      AppDelegate.feedFailure(url, .failed(.unreadable))
        == "--feed /Users/me/tu-archivo.wav: The file could not be read")
    #expect(AppDelegate.feedFailure(url, .playing(sampleRate: 48000)) == nil)
  }

  @Test("System Output waits for the first-run window before the capture starts")
  func systemOutputWaitsForPermissionWindow() throws {
    let overlay = try #require(OverlayController(settings: SettingValues()))
    var wanted = 0
    overlay.onCaptureWanted = { wanted += 1 }
    let missing = URL(filePath: "/nonexistent/none.wav")
    #expect(overlay.follow(.file(missing), in: nil) == .failed(.unreadable))
    overlay.follow(.systemOutput, in: nil)
    #expect(wanted == 1)
    #expect(overlay.meter.capture == CaptureState())  // nothing started
    overlay.stop()
  }

  @Test("Choosing a file that failed again tries it again")
  func retryFailedFile() throws {
    let folder = try TemporaryFolder()
    let url = folder.url.appending(path: "later.wav")
    let overlay = try #require(OverlayController(settings: SettingValues()))
    let model = MeterMenuModel(store: SettingsStore(defaults: nil), presetFolder: nil)
    let sources = SourceController(overlay: overlay, model: model, sources: nil)
    sources.choose(.file(url))
    #expect(model.fileState == .failed(.unreadable))
    try TestWAV.write(to: url, frames: 480)
    sources.choose(.file(url))
    #expect(model.fileState == .playing(sampleRate: 48000))
    sources.stop()
    overlay.stop()
  }

  @Test("Probe exit codes for a source: 2 not listed, 1 listed but not drawing, 0 drawing")
  func probeExitCodes() {
    let menu = MeterMenuModel(store: SettingsStore(defaults: nil), presetFolder: nil)
    func code(rendering: Bool) -> Int32 {
      MeterProbe.exitCode(for: report(SourceReport(file: menu), rendering: rendering))
    }
    #expect(code(rendering: true) == 2)  // the file is not playing
    menu.source = .file(URL(filePath: "/tmp/Mix.wav"))
    menu.fileState = .playing(sampleRate: 48000)
    #expect(code(rendering: false) == 1)
    #expect(code(rendering: true) == 0)
    let absent = SourceReport(menu, instance: "Nowhere")
    #expect(MeterProbe.exitCode(for: report(absent, rendering: true)) == 2)
  }

  private typealias SourceReport = MeterProbe.SourceReport

  private func report(_ source: SourceReport, rendering: Bool) -> MeterProbe.Report {
    MeterProbe.Report(
      phase: .starting, capturing: false, failedStep: "", status: 0, sampleRate: 0, channels: 0,
      rebuilds: 0, signal: "unknown", notice: nil, rendering: rendering, idle: false,
      overlay: nil, menuBar: nil, source: source, version: "test")
  }
}
