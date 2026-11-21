import Foundation
import NMRCoreC

/// A named look: of its settings, only the entries presets store matter. Saving drops control
/// characters from the name, NUL included.
struct Preset: Equatable, Sendable {
  var name: String
  var settings: SettingValues
}

/// The factory presets and the user's preset files, shared with the plugin.
enum Presets {
  /// Mix, Stage, the original mode's preset and Classic.
  static let factory: [Preset] = (0..<nmr_presets_factory_count()).map { index in
    Preset(
      name: borrowedString(nmr_presets_factory_name(index)),
      settings: SettingValues(adopting: nmr_presets_factory_settings(index)))
  }

  /// The user's preset folder (not created); nil without a home folder.
  static let directory = URL(folderFromC: takenString(nmr_presets_directory()))

  /// The preset files in `folder`, sorted by name ignoring case.
  static func list(in folder: URL) -> [UserFile] {
    UserFile.adopt(nmr_presets_list(folder.cPath))
  }

  /// The preset in `file`, named after the file, and what decoding it found; no preset when the
  /// file could not be read (see `report.status`).
  static func load(_ file: URL) -> (preset: Preset?, report: SettingsReport) {
    var name: UnsafeMutablePointer<CChar>?
    var report = nmr_json_report()
    let handle = nmr_presets_load(file.cPath, &name, &report)
    let shown = takenString(name) ?? ""
    guard let handle else { return (nil, SettingsReport(report)) }
    return (Preset(name: shown, settings: SettingValues(adopting: handle)), SettingsReport(report))
  }

  /// Saves `preset` into `folder` (created if needed) as `fileName(for:)`, replacing a file of
  /// that name. Names that differ only in case share a file on a default APFS volume: ask before
  /// replacing one. Blocks until the file reaches the drive: call it off the main thread.
  static func save(_ preset: Preset, in folder: URL) throws(POSIXError) -> URL {
    var error: Int32 = 0
    let name = preset.name.withoutNUL
    let path = preset.settings.withHandle { nmr_presets_save(folder.cPath, name, $0, &error) }
    guard let path = takenString(path) else { throw POSIXError(errno: error) }
    return URL(filePath: path)
  }

  /// Deletes a preset file: one ending in .json in any case, never a folder or another file.
  static func remove(_ file: URL) throws(POSIXError) {
    var error: Int32 = 0
    guard nmr_presets_remove(file.cPath, &error) else { throw POSIXError(errno: error) }
  }

  /// The file a preset name is saved under ("Mix" gives "Mix.json").
  static func fileName(for name: String) -> String {
    takenString(nmr_presets_file_name(name.withoutNUL)) ?? ""
  }

  /// `preset` as JSON, for exporting it.
  static func json(for preset: Preset) -> String {
    let name = preset.name.withoutNUL
    guard let json = preset.settings.withHandle({ takenString(nmr_presets_encode(name, $0)) })
    else { fatalError("out of memory for preset JSON") }
    return json
  }
}

extension SettingValues {
  /// These settings with every entry presets store taken from `preset`.
  func applying(_ preset: SettingValues) -> SettingValues {
    let applied = withHandle { current in preset.withHandle { nmr_presets_apply(current, $0) } }
    return SettingValues(adopting: applied)
  }
}
