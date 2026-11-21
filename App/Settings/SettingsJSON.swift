import NMRCoreC

/// What decoding settings JSON found.
struct SettingsReport: Equatable, Sendable {
  enum Status: Equatable, Sendable {
    case ok
    case notJSON
    /// JSON without a version and a settings object.
    case notSettings
    /// Over 256 KiB.
    case tooLarge
    /// A file that could not be read.
    case unreadable
  }

  var status: Status
  /// The document's version.
  var version: Int
  /// Written by a newer version: loaded as far as this one understands it.
  var newer: Bool
  /// Keys the document may not set: unknown, or not stored in presets.
  var ignored: Int
  /// Values of the wrong type or not among the choices: defaults used.
  var invalid: Int
  /// Numbers clamped or rounded, or a preset name cleaned.
  var adjusted: Int
}

extension SettingsReport {
  init(_ report: nmr_json_report) {
    self.init(
      status: Status(report.status), version: Int(report.version), newer: report.newer,
      ignored: Int(report.ignored), invalid: Int(report.invalid), adjusted: Int(report.adjusted))
  }
}

extension SettingsReport.Status {
  init(_ status: nmr_json_status) {
    switch status {
    case NMR_JSON_OK: self = .ok
    case NMR_JSON_NOT_JSON: self = .notJSON
    case NMR_JSON_NOT_SETTINGS: self = .notSettings
    case NMR_JSON_TOO_LARGE: self = .tooLarge
    default: self = .unreadable
    }
  }
}

extension SettingValues {
  /// Every setting as versioned JSON (the format the plugin keeps its state in).
  var json: String {
    guard let json = withHandle({ takenString(nmr_settings_encode($0)) }) else {
      fatalError("out of memory for settings JSON")
    }
    return json
  }

  /// Settings from JSON: the defaults unless `report.status` is `.ok`.
  static func decode(json: String) -> (values: SettingValues, report: SettingsReport) {
    var report = nmr_json_report()
    var json = json
    let handle = json.withUTF8 { bytes in
      bytes.withMemoryRebound(to: CChar.self) { text in
        nmr_settings_decode(text.baseAddress, text.count, &report)
      }
    }
    return (SettingValues(adopting: handle), SettingsReport(report))
  }
}
