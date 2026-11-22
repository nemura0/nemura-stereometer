import AppKit
import Foundation
import NMRCoreC
import Testing

@testable import App

/// What the app makes of the capture's reports: the signal, the notice on the meter, what it
/// remembers between runs, and the permission window's text.
@Suite("Capture")
struct CaptureTests {
  private func status(code: Int32 = 0, signal: UInt8) -> nmr_capture_status {
    nmr_capture_status(
      status: code, failed_step: nil, sample_rate: 48_000, channels: 2, rebuilds: 1,
      signal: signal)
  }

  private func capturing(_ signal: CaptureState.Signal) -> CaptureState {
    var state = CaptureState()
    state.phase = .capturing(sampleRate: 48_000, channels: 2)
    state.signal = signal
    return state
  }

  @Test("The signal comes from the report; an unknown value is no signal")
  func signalFromStatus() {
    #expect(CaptureState(status(signal: 0)).signal == .unknown)
    #expect(CaptureState(status(signal: 1)).signal == .sound)
    #expect(CaptureState(status(signal: 2)).signal == .silenceWhilePlaying)
    #expect(CaptureState(status(signal: 9)).signal == .unknown)
    #expect(CaptureState().signal == .unknown)
  }

  @Test("No notice while starting, while silent, or once sound arrives")
  func noNotice() {
    #expect(CaptureNotice(CaptureState()) == nil)
    #expect(CaptureNotice(capturing(.unknown)) == nil)
    #expect(CaptureNotice(capturing(.sound)) == nil)
  }

  @Test("Silence while another app plays points at the permission")
  func silenceNotice() throws {
    let notice = try #require(CaptureNotice(capturing(.silenceWhilePlaying)))
    #expect(notice == .silenceWhilePlaying)
    #expect(notice.message.contains("permission"))
    #expect(notice.actionTitle == "How to Fix…")
  }

  @Test("A failed capture says where it failed, before anything about the signal")
  func failedNotice() throws {
    var state = CaptureState()
    state.phase = .failed(step: "AudioDeviceStart", status: -50)
    state.signal = .silenceWhilePlaying
    let notice = try #require(CaptureNotice(state))
    #expect(notice == .failed(step: "AudioDeviceStart", status: -50))
    #expect(notice.message.contains("AudioDeviceStart"))
    #expect(notice.message.contains("-50"))
    #expect(notice.actionTitle == "Try Again")
  }

  @Test("The memory starts empty and keeps what it learns")
  func memory() throws {
    let suite = "test.capture.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let memory = CaptureMemory(defaults: defaults)
    #expect(!memory.introShown)
    #expect(!memory.soundSeen)
    memory.remember(capturing(.unknown))
    memory.remember(capturing(.silenceWhilePlaying))
    #expect(!memory.soundSeen)
    memory.remember(capturing(.sound))
    memory.introShown = true
    let later = CaptureMemory(defaults: defaults)
    #expect(later.soundSeen)
    #expect(later.introShown)
  }

  @Test("The intro says why the permission is asked for and that audio stays on the Mac")
  func introText() {
    let intro = PermissionContent(.intro)
    #expect(intro.body.contains("never leaves"))
    #expect(intro.primary == "Continue")
    #expect(intro.secondary == nil)
    #expect(intro.steps.isEmpty)
  }

  @Test("The help names the System Settings pane and section, and opens that pane")
  func helpText() {
    let help = PermissionContent(.help)
    let steps = help.steps.joined(separator: " ")
    #expect(steps.contains("Screen & System Audio Recording"))
    #expect(steps.contains("System Audio Recording Only"))
    #expect(steps.contains(String(cString: nmr_product_name())))
    #expect(help.primary == "Open System Settings")
    #expect(help.secondary == "Close")
    #expect(PermissionContent.settingsURL.absoluteString.hasSuffix("?Privacy_AudioCapture"))
  }
}

/// The notice over the meter, laid out without a window: it must stay readable in the smallest
/// window and never set the window's size.
@Suite("Capture notice view")
@MainActor
struct NoticeViewTests {
  private static let notices: [CaptureNotice] = [
    .failed(step: "AudioDeviceCreateIOProcID", status: -2_147_483_648), .silenceWhilePlaying,
  ]

  @Test("At the smallest window the whole message fits inside the meter, button included")
  func fitsSmallest() {
    let notice = NoticeView()
    let side = OverlayWindow.minimumSide
    for message in Self.notices {
      notice.show(message)
      let frame = NoticeView.frame(for: notice, in: NSRect(x: 0, y: 0, width: side, height: side))
      #expect(frame.minX >= NoticeView.inset && frame.maxX <= side - NoticeView.inset)
      #expect(frame.minY >= NoticeView.inset)
      // Below the hover controls (22 pt high, 10 pt from the top).
      #expect(frame.maxY <= side - 2 * NoticeView.inset - 22)
      #expect(notice.labelFitsWithoutTruncation(width: frame.width))
    }
  }

  @Test("Wide windows cap its width; it keeps to the bottom, centered")
  func wide() {
    let notice = NoticeView()
    notice.show(.silenceWhilePlaying)
    let frame = NoticeView.frame(for: notice, in: NSRect(x: 0, y: 0, width: 720, height: 720))
    #expect(frame.width == NoticeView.maximumWidth)
    #expect(abs(frame.midX - 360) < 0.5)
    #expect(frame.minY == NoticeView.inset)
  }

  @Test("It sets no constraints the window could follow, shown or hidden")
  func noConstraints() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
    let notice = NoticeView()
    notice.place(in: container)
    notice.show(.failed(step: "x", status: 1))
    notice.show(nil)
    #expect(container.constraints.isEmpty)
    #expect(notice.constraints.isEmpty)
    #expect(notice.translatesAutoresizingMaskIntoConstraints)
  }

  @Test("The message is not selectable, so a click never takes the keyboard")
  func notSelectable() {
    let notice = NoticeView()
    notice.show(.silenceWhilePlaying)
    #expect(!notice.labelIsSelectable)
  }

  @Test("Without mouse events (click-through) the action is not offered")
  func noActionWhenClickThrough() {
    let notice = NoticeView()
    notice.show(.failed(step: "x", status: 1))
    #expect(notice.showsAction)
    notice.allowsAction = false
    #expect(!notice.showsAction)
    notice.allowsAction = true
    #expect(notice.showsAction)
  }
}

@Suite("Permission window")
struct PermissionWindowTests {
  @Test("Help asked for while the intro is open keeps the intro (the capture has not started)")
  func helpDuringIntro() {
    #expect(PermissionWindow.mode(showing: .intro, asked: .help) == .intro)
    #expect(PermissionWindow.mode(showing: nil, asked: .help) == .help)
    #expect(PermissionWindow.mode(showing: .help, asked: .help) == .help)
    #expect(PermissionWindow.mode(showing: nil, asked: .intro) == .intro)
  }
}
