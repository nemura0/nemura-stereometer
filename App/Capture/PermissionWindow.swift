import AppKit
import NMRCoreC
import SwiftUI

/// The words of the permission window (docs/PROMPT.md §6, first run): the intro before the first
/// capture, and the help for a permission that looks denied.
struct PermissionContent: Equatable {
  enum Mode: Equatable { case intro, help }

  /// System Settings › Privacy & Security › Screen & System Audio Recording.
  static let settingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

  let mode: Mode
  let symbol: String
  let title: String
  let body: String
  let steps: [String]
  let primary: String
  let secondary: String?

  init(_ mode: Mode) {
    self.mode = mode
    let product = String(cString: nmr_product_name())
    switch mode {
    case .intro:
      symbol = "waveform"
      title = "See what your Mac plays"
      body = """
        \(product) draws the sound your Mac sends to its output. To hear it, macOS asks once \
        for permission to capture system audio. The audio never leaves this Mac: it is drawn, \
        and never recorded, saved or sent.
        """
      steps = []
      primary = "Continue"
      secondary = nil
    case .help:
      symbol = "speaker.slash"
      title = "Turn on system audio capture"
      body = """
        Something is playing, but only silence reaches the meter. When the permission is off, \
        macOS sends silence instead of an error. (A stopped DAW also plays silence: if that is \
        the case, press play.)
        """
      steps = [
        "Open System Settings › Privacy & Security › Screen & System Audio Recording.",
        "Under System Audio Recording Only, turn on \(product).",
        "Quit \(product) and open it again.",
      ]
      primary = "Open System Settings"
      secondary = "Close"
    }
  }
}

/// The permission window: a small dark window in front of everything, shown by the app delegate.
@MainActor
final class PermissionWindow: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private var shown: PermissionContent.Mode?
  private var onClose: [() -> Void] = []

  /// What the window shows when `asked` comes while it shows `showing`: the intro stays until it
  /// is closed (before it, no capture has started, so there is nothing to help with yet).
  nonisolated static func mode(showing: PermissionContent.Mode?, asked: PermissionContent.Mode)
    -> PermissionContent.Mode
  {
    showing == .intro ? .intro : asked
  }

  /// Shows `asked` (see mode(showing:asked:)); `onClose` runs once when the window closes.
  func show(_ asked: PermissionContent.Mode, onClose: (() -> Void)? = nil) {
    if let onClose { self.onClose.append(onClose) }
    let mode = Self.mode(showing: shown, asked: asked)
    shown = mode
    let content = PermissionContent(mode)
    let view = PermissionView(
      content: content,
      primary: { [weak self] in self?.primary(content.mode) },
      secondary: { [weak self] in self?.close() })
    let window = self.window ?? makeWindow()
    window.contentViewController = NSHostingController(rootView: view)
    window.center()
    self.window = window
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  func close() { window?.close() }

  func windowWillClose(_ notification: Notification) {
    window = nil
    shown = nil
    let pending = onClose
    onClose = []
    for action in pending { action() }
  }

  private func primary(_ mode: PermissionContent.Mode) {
    switch mode {
    case .intro: close()
    // The window stays open, so the steps can be read while System Settings is in front.
    case .help: NSWorkspace.shared.open(PermissionContent.settingsURL)
    }
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: PermissionView.width, height: 240),
      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.level = .floating  // over the meter, which floats too
    // Where the user is, even over a full-screen DAW (the meter floats there too).
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    window.delegate = self
    return window
  }
}

private struct PermissionView: View {
  static let width: CGFloat = 440
  private static let iris = Color(red: 0x89 / 255, green: 0x93 / 255, blue: 0xFF / 255)

  let content: PermissionContent
  let primary: () -> Void
  let secondary: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Image(systemName: content.symbol)
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(Self.iris)
          .frame(width: 40, height: 40)
          .background(Self.iris.opacity(0.16), in: Circle())
        Text(content.title).font(.title2.weight(.semibold))
      }
      Text(content.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if !content.steps.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(content.steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text("\(index + 1)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(Self.iris)
              Text(step).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
      }
      HStack {
        Spacer()
        if let secondary = content.secondary {
          Button(secondary, action: self.secondary).keyboardShortcut(.cancelAction)
        }
        Button(content.primary, action: primary)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .tint(Self.iris)
      }
      .padding(.top, 4)
    }
    .padding(.horizontal, 24)
    .padding(.top, 30)
    .padding(.bottom, 20)
    .frame(width: Self.width)
  }
}
