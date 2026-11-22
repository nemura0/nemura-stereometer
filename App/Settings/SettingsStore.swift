import Foundation
import Observation
import os

/// The app's settings: what the meter, the popover and the Settings window show and change.
///
/// Kept in the app's defaults as the same versioned JSON the plugin stores, written on every
/// change. The first run starts from the NEMURA preset. Click-through always starts off: a
/// window that ignores the mouse is never the first thing the user sees.
@MainActor
@Observable
final class SettingsStore {
  static let key = "settings"

  private(set) var values: SettingValues
  @ObservationIgnored private let defaults: UserDefaults?
  @ObservationIgnored private var observers: [(SettingValues) -> Void] = []
  @ObservationIgnored private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app", category: "settings")

  /// `defaults` nil (the probe): the first-run settings, and nothing is written.
  init(defaults: UserDefaults?) {
    self.defaults = defaults
    var values = Self.load(from: defaults)
    values.set(.clickThrough, to: 0)
    self.values = values
  }

  /// `body` runs after every change, with the new values (not for the current ones).
  func observe(_ body: @escaping (SettingValues) -> Void) {
    observers.append(body)
  }

  func update(_ change: (inout SettingValues) -> Void) {
    var changed = values
    change(&changed)
    replace(changed)
  }

  func replace(_ new: SettingValues) {
    guard new != values else { return }
    values = new
    defaults?.set(new.json, forKey: Self.key)
    for observer in observers { observer(new) }
  }

  /// Takes the look from `preset`; the window behavior and the frame rate stay.
  func apply(_ preset: Preset) {
    replace(values.applying(preset.settings))
  }

  /// Whether the look is `preset`'s.
  func matches(_ preset: Preset) -> Bool {
    values.applying(preset.settings) == values
  }

  /// The first of `presets` whose look this is.
  func matchingPreset(in presets: [Preset]) -> Preset? {
    presets.first(where: matches)
  }

  /// The NEMURA preset (the original mode) over the defaults.
  nonisolated static var firstSettings: SettingValues {
    let settings = SettingValues()
    guard let nemura = Presets.factory.first(where: { $0.settings.choice(.mode) == "original" })
    else { return settings }
    return settings.applying(nemura.settings)
  }

  private static func load(from defaults: UserDefaults?) -> SettingValues {
    guard let stored = defaults?.object(forKey: key) else { return firstSettings }
    guard let json = stored as? String else {
      log.error("the saved settings are not text: starting from the first-run settings")
      return firstSettings
    }
    let (values, report) = SettingValues.decode(json: json)
    guard report.status == .ok else {
      log.error("the saved settings could not be read: starting from the first-run settings")
      return firstSettings
    }
    return values
  }
}
