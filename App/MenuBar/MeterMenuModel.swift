import Foundation
import Observation

/// What the menu-bar popover shows and changes: the source, the mode, the preset, the
/// background opacity and click-through. Changes go to the settings store, which the meter
/// follows.
@MainActor
@Observable
final class MeterMenuModel {
  /// Shown when the look matches no preset.
  static let custom = "Custom"

  let store: SettingsStore
  /// The factory presets, then the user's (reloaded each time the popover opens).
  let presets: [Preset] = Presets.factory
  private(set) var userPresets: [Preset] = []
  var capture = CaptureState()
  /// Click-through's global shortcut; nil when another app holds it.
  var clickThroughShortcut: String? = HotKeys.Action.toggleClickThrough.shortcut
  @ObservationIgnored private let presetFolder: URL?

  init(store: SettingsStore, presetFolder: URL? = Presets.directory) {
    self.store = store
    self.presetFolder = presetFolder
    reloadPresets()
  }

  /// Reads the user's presets again (they may have changed in the plugin or in Finder).
  func reloadPresets() {
    guard let presetFolder else {
      userPresets = []
      return
    }
    userPresets = Presets.loadAll(in: presetFolder).map(\.preset)
  }

  var mode: MeterMode {
    get { MeterMode(rawValue: store.values.choice(.mode)) ?? .goniometer }
    set { store.update { $0.set(.mode, choice: newValue.rawValue) } }
  }

  func modeLabel(_ mode: MeterMode) -> String {
    Schema.spec(.mode)?.choices.first { $0.key == mode.rawValue }?.label ?? mode.rawValue
  }

  /// The preset the look is, or `custom`.
  var presetTitle: String {
    store.matchingPreset(in: presets + userPresets)?.name ?? Self.custom
  }

  func choosePreset(_ preset: Preset) {
    store.apply(preset)
  }

  /// The background's opacity, 0…100 %.
  var opacity: Double {
    get { store.values.number(.backgroundOpacity) }
    set { store.update { $0.set(.backgroundOpacity, to: newValue) } }
  }

  var clickThrough: Bool {
    get { store.values.flag(.clickThrough) }
    set { store.update { $0.set(.clickThrough, to: newValue ? 1 : 0) } }
  }

  /// One line about the system output capture.
  var sourceStatus: String {
    switch capture.phase {
    case .starting:
      return "Starting…"
    case .failed(_, let status):
      return "Not capturing (error \(status))"
    case .capturing(let rate, let channels):
      if capture.signal == .silenceWhilePlaying { return "Only silence arrives" }
      // The app is in English: "44.1 kHz" whatever the region's decimal separator.
      let kHz = (rate / 1000).formatted(
        .number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US_POSIX")))
      let layout = channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels) channels"
      return "\(kHz) kHz, \(layout)"
    }
  }
}
