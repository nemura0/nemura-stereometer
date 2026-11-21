import NMRCoreC

/// One entry of the shared settings schema, read through the C API.
struct SettingSpec: Sendable {
  struct Choice: Equatable, Sendable {
    let key: String
    let label: String
  }

  /// A named value (the trail time's response presets).
  struct Stop: Equatable, Sendable {
    let label: String
    let value: Double
  }

  let key: String
  let label: String
  let unit: String
  let group: String
  let type: SettingType
  let scope: SettingScope
  let inPresets: Bool
  let minimum: Double
  let maximum: Double
  let step: Double
  let defaultValue: Double
  let defaultText: String
  let maxLength: Int
  let choices: [Choice]
  let stops: [Stop]
}

enum Schema {
  /// Every entry, in the schema's order.
  static let entries: [SettingSpec] = (0..<nmr_settings_count()).compactMap(SettingSpec.init)

  static func spec(_ key: SettingKey) -> SettingSpec? {
    entries.first { $0.key == key.rawValue }
  }
}

extension SettingSpec {
  /// Entry `index`; nil past the end, or for a type or scope this build does not know.
  init?(index: UInt32) {
    var spec = nmr_setting_spec()
    guard nmr_settings_spec(index, &spec), let type = SettingType(spec.type),
      let scope = SettingScope(spec.scope)
    else { return nil }
    self.key = string(spec.key)
    self.label = string(spec.label)
    self.unit = string(spec.unit)
    self.group = string(nmr_settings_group_key(spec.group))
    self.type = type
    self.scope = scope
    self.inPresets = spec.preset
    self.minimum = spec.min
    self.maximum = spec.max
    self.step = spec.step
    self.defaultValue = spec.default_value
    self.defaultText = string(spec.default_text)
    self.maxLength = Int(spec.max_length)
    self.choices = (0..<spec.choice_count).compactMap { choice in
      guard let key = nmr_settings_choice_key(index, choice),
        let label = nmr_settings_choice_label(index, choice)
      else { return nil }
      return Choice(key: String(cString: key), label: String(cString: label))
    }
    self.stops = (0..<spec.stop_count).compactMap { stop in
      var label: UnsafePointer<CChar>?
      var value = 0.0
      guard nmr_settings_stop(index, stop, &label, &value), let label else { return nil }
      return Stop(label: String(cString: label), value: value)
    }
  }
}

extension SettingType {
  init?(_ type: nmr_setting_type) {
    switch type {
    case NMR_SETTING_BOOL: self = .bool
    case NMR_SETTING_INT: self = .int
    case NMR_SETTING_FLOAT: self = .float
    case NMR_SETTING_CHOICE: self = .choice
    case NMR_SETTING_COLOR: self = .color
    case NMR_SETTING_TEXT: self = .text
    default: return nil
    }
  }
}

extension SettingScope {
  init?(_ scope: nmr_setting_scope) {
    switch scope {
    case NMR_SCOPE_SHARED: self = .shared
    case NMR_SCOPE_APP: self = .app
    case NMR_SCOPE_PLUGIN: self = .plugin
    default: return nil
    }
  }
}

private func string(_ text: UnsafePointer<CChar>?) -> String {
  text.map { String(cString: $0) } ?? ""
}
