import Foundation
import Observation

/// One sidebar entry of the Settings window: a schema group and its entries the app uses.
struct SettingsGroup: Identifiable, Equatable, Sendable {
  let key: String
  let label: String
  let keys: [SettingKey]
  var id: String { key }
}

/// Why a preset file was not read or written.
enum PresetError: Error, Equatable, CustomStringConvertible {
  /// Missing, not a regular file, or unreadable.
  case unreadable
  /// Not preset JSON (or over 256 KiB).
  case notAPreset
  /// The preset's file was removed elsewhere (Finder, the plugin).
  case missing
  case notWritten(POSIXError)

  var description: String {
    switch self {
    case .unreadable: "The file could not be read."
    case .notAPreset: "The file is not a preset."
    case .missing: "The preset file is no longer there."
    case .notWritten(let error): "The preset could not be written: \(error.reason)."
    }
  }
}

extension POSIXError {
  /// The system's words for the error ("Permission denied").
  var reason: String { String(cString: strerror(code.rawValue)) }
}

/// What the Settings window shows and changes: every setting the app uses, generated from the
/// shared schema, plus the presets and colormaps. Changes go to the settings store, so the
/// meter itself is the preview. File work (saving, importing, exporting, deleting) runs off the
/// main thread: preset and colormap files are written through to the drive.
@MainActor
@Observable
final class SettingsModel {
  let store: SettingsStore
  let groups: [SettingsGroup]
  private(set) var userPresets: [Preset] = []
  /// The original colormaps, then the user's.
  private(set) var colormaps: [Colormap] = []

  @ObservationIgnored private var presetFiles: [String: URL] = [:]
  @ObservationIgnored private let presetFolder: URL?
  @ObservationIgnored private let colormapFolder: URL?

  init(
    store: SettingsStore, presetFolder: URL? = Presets.directory,
    colormapFolder: URL? = Colormaps.directory
  ) {
    self.store = store
    self.presetFolder = presetFolder
    self.colormapFolder = colormapFolder
    groups = Schema.groups.compactMap { group in
      let keys = Schema.entries.filter { $0.group == group.key && $0.scope != .plugin }
        .compactMap { SettingKey(rawValue: $0.key) }
      return keys.isEmpty ? nil : SettingsGroup(key: group.key, label: group.label, keys: keys)
    }
    reload()
  }

  /// Lists the user's presets and colormaps again (the plugin or Finder may have changed them).
  func reload() {
    let loaded = presetFolder.map(Presets.loadAll(in:)) ?? []
    userPresets = loaded.map(\.preset)
    presetFiles = Dictionary(loaded.map { ($0.preset.name, $0.file) }) { first, _ in first }
    let user = (colormapFolder.map(Colormaps.list(in:)) ?? []).map {
      Colormap(key: Colormaps.key(forUserColormap: $0.name), label: $0.name)
    }
    colormaps = Colormaps.builtins + user.filter { !$0.key.isEmpty }
  }

  // MARK: - Values

  func reset(_ group: SettingsGroup) {
    store.update { values in
      for key in group.keys { values.reset(key) }
    }
  }

  func apply(_ preset: Preset) {
    store.apply(preset)
  }

  /// Whether the setting changes what the meter draws in the current settings (a solid color
  /// only in solid color mode, the colormap in the others, the log range in the log modes).
  static func applies(_ key: SettingKey, in values: SettingValues) -> Bool {
    switch key {
    case .solidColor: values.choice(.colorMode) == ColorMode.solid.rawValue
    case .colormap: values.choice(.colorMode) != ColorMode.solid.rawValue
    case .logRangeDb: values.choice(.mode).hasSuffix("_log")
    default: true
    }
  }

  /// Ranges a hundredfold wide or more (the trail, the meter integration) slide on a log scale,
  /// so their short end gets room.
  static func usesLogScale(_ spec: SettingSpec) -> Bool {
    spec.minimum > 0 && spec.maximum / spec.minimum >= 100
  }

  /// Where `value` sits on the entry's slider, 0…1.
  static func position(of value: Double, in spec: SettingSpec) -> Double {
    let clamped = min(max(value, spec.minimum), spec.maximum)
    guard spec.maximum > spec.minimum else { return 0 }
    if usesLogScale(spec) {
      return log(clamped / spec.minimum) / log(spec.maximum / spec.minimum)
    }
    return (clamped - spec.minimum) / (spec.maximum - spec.minimum)
  }

  /// The value at a slider position, clamped to the range and rounded to the entry's step.
  static func value(at position: Double, in spec: SettingSpec) -> Double {
    let p = min(max(position, 0), 1)
    let raw =
      usesLogScale(spec)
      ? spec.minimum * pow(spec.maximum / spec.minimum, p)
      : spec.minimum + p * (spec.maximum - spec.minimum)
    guard spec.step > 0 else { return raw }
    let stepped = spec.minimum + ((raw - spec.minimum) / spec.step).rounded() * spec.step
    // Steps like 0.1 leave binary noise: keep the step's decimals only.
    let decimals = pow(10, Double(decimalPlaces(for: spec)))
    return min(max((stepped * decimals).rounded() / decimals, spec.minimum), spec.maximum)
  }

  /// "15 ms", "+6.0 dB", "×2", "100 %": the step's decimals, a sign where the range goes below
  /// zero, the true minus sign.
  static func format(_ value: Double, for spec: SettingSpec) -> String {
    let number = abs(value).formatted(
      .number.precision(.fractionLength(decimalPlaces(for: spec)))
        .locale(Locale(identifier: "en_US_POSIX")).grouping(.never))
    let isZero = number.allSatisfy { $0 == "0" || $0 == "." }
    let sign = value < 0 && !isZero ? "−" : spec.minimum < 0 && !isZero ? "+" : ""
    switch spec.unit {
    case "×": return "×\(sign)\(number)"
    case "": return sign + number
    default: return "\(sign)\(number) \(spec.unit)"
    }
  }

  private static func decimalPlaces(for spec: SettingSpec) -> Int {
    decimalPlaces(forStep: spec.step)
  }

  /// The decimals a step needs: 0 for 1 or 5, 1 for 0.5, 2 for 0.25 (at most 6).
  static func decimalPlaces(forStep step: Double) -> Int {
    guard step > 0, step.isFinite else { return 0 }
    return (0...6).first { places in
      let scaled = step * pow(10, Double(places))
      return abs(scaled - scaled.rounded()) < 1e-9 * max(1, scaled)
    } ?? 6
  }

  // MARK: - Presets

  /// Saves the current look as a user preset, replacing one of that name.
  func saveCurrent(as name: String) async throws(PresetError) {
    guard let folder = presetFolder else { throw .notWritten(POSIXError(.ENOENT)) }
    let preset = Preset(name: name, settings: store.values)
    let result = await Task.detached { () -> Result<URL, POSIXError> in
      Result { () throws(POSIXError) in try Presets.save(preset, in: folder) }
    }.value
    if case .failure(let error) = result { throw .notWritten(error) }
    reload()
  }

  /// Writes `preset` as a JSON file at `url` (for sharing, or for the plugin on another Mac).
  func export(_ preset: Preset, to url: URL) async throws(PresetError) {
    let json = Presets.json(for: preset)
    let result = await Task.detached { () -> Result<Void, POSIXError> in
      do {
        try Data(json.utf8).write(to: url, options: .atomic)
        return .success(())
      } catch let error as NSError {
        // Foundation wraps the POSIX error a failed write reports; EIO when there is none.
        let posix = [error, error.userInfo[NSUnderlyingErrorKey] as? NSError]
          .compactMap { $0 }.first { $0.domain == NSPOSIXErrorDomain }
        return .failure(POSIXError(errno: Int32(posix?.code ?? Int(EIO))))
      }
    }.value
    if case .failure(let error) = result { throw .notWritten(error) }
  }

  /// Copies a preset file into the user's presets under its file name, replacing one of that
  /// name, and returns it.
  func importPreset(from url: URL) async throws(PresetError) -> Preset {
    guard let folder = presetFolder else { throw .notWritten(POSIXError(.ENOENT)) }
    let result = await Task.detached { () -> Result<Preset, PresetError> in
      let (loaded, report) = Presets.load(url)
      guard let loaded else {
        return .failure(report.status == .unreadable ? .unreadable : .notAPreset)
      }
      return Result { () throws(POSIXError) in try Presets.save(loaded, in: folder) }
        .map { _ in loaded }.mapError { .notWritten($0) }
    }.value
    let preset = try result.get()
    reload()
    return preset
  }

  /// Deletes a user preset's file (factory presets have none).
  func delete(_ preset: Preset) async throws(PresetError) {
    guard let file = presetFiles[preset.name] else { throw .missing }
    let result = await Task.detached { () -> Result<Void, POSIXError> in
      Result { () throws(POSIXError) in try Presets.remove(file) }
    }.value
    if case .failure(let error) = result {
      reload()
      throw error.code == .ENOENT ? .missing : .notWritten(error)
    }
    reload()
  }

  // MARK: - Colormaps

  /// Imports a MiniMeters `.map` file the user chose, and returns its colormap.
  func importColormap(from url: URL) async throws(ColormapImportError) -> Colormap {
    guard let folder = colormapFolder else { throw .notWritten(POSIXError(.ENOENT)) }
    let result = await Task.detached { () -> Result<URL, ColormapImportError> in
      Result { () throws(ColormapImportError) in try Colormaps.importMap(url, into: folder).file }
    }.value
    let file = try result.get()
    reload()
    let name = file.deletingPathExtension().lastPathComponent
    return colormaps.last { $0.label == name }
      ?? Colormap(key: Colormaps.key(forUserColormap: name), label: name)
  }
}
