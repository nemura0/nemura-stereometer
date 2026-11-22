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
  /// The plugin instances sending now (PluginSources), for the source picker.
  var instances: [PluginInstance] = []
  /// What the meter shows.
  var source: MeterSource = .systemOutput
  /// How the chosen instance is doing, when `source` is one.
  var instanceState: InstanceState = .waiting
  /// `--feed`: the file offered as a source, and how it plays when chosen.
  var feedFile: URL?
  var fileState: FileState = .failed(.unreadable)
  /// The user picked a source.
  @ObservationIgnored var onChooseSource: ((MeterSource) -> Void)?
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

  func choose(_ source: MeterSource) {
    onChooseSource?(source)
  }

  static let systemOutput = "System Output"

  /// The source's name: "System Output" or the instance's.
  var sourceTitle: String {
    switch source {
    case .systemOutput: Self.systemOutput
    case .instance(let instance): title(for: instance)
    case .file(let url): Self.fileTitle(url)
    }
  }

  /// The instance's title in the picker: "Bass — Live", then "Bass — Live (2)" for a second
  /// instance of that name in that app (in listing order); its own title when it is not listed.
  func title(for instance: PluginInstance) -> String {
    guard let index = instances.firstIndex(where: { $0.id == instance.id }) else {
      return instance.title
    }
    let title = instances[index].title
    let earlier = instances[..<index].filter { $0.title == title }.count
    return earlier == 0 ? title : "\(title) (\(earlier + 1))"
  }

  static func fileTitle(_ url: URL) -> String { "File: \(url.lastPathComponent)" }

  /// One line about the source: the capture's state, or the chosen instance's.
  var sourceStatus: String {
    if case .file = source {
      switch fileState {
      case .playing(let rate): return Self.format(rate: rate) + ", looping"
      case .failed(let problem): return problem.description
      }
    }
    guard case .instance(let instance) = source else { return captureStatus }
    switch instanceState {
    case .waiting: return "Not sending"
    case .quiet: return "Paused in the host"
    case .sending: return Self.format(rate: instance.sampleRate, channels: instance.channels)
    }
  }

  private var captureStatus: String {
    switch capture.phase {
    case .starting:
      return "Starting…"
    case .failed(_, let status):
      return "Not capturing (error \(status))"
    case .capturing(let rate, let channels):
      if capture.signal == .silenceWhilePlaying { return "Only silence arrives" }
      return Self.format(rate: rate, channels: channels)
    }
  }

  /// "44.1 kHz, mono", in English whatever the region's decimal separator.
  static func format(rate: Double, channels: Int) -> String {
    let layout = channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels) channels"
    return "\(format(rate: rate)), \(layout)"
  }

  /// "44.1 kHz".
  static func format(rate: Double) -> String {
    let kHz = (rate / 1000).formatted(
      .number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US_POSIX")))
    return "\(kHz) kHz"
  }
}
