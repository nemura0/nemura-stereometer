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

  /// The groups' keys and labels, in the schema's order.
  static let groups: [(key: String, label: String)] = (0..<nmr_settings_group_count()).map {
    (borrowedString(nmr_settings_group_key($0)), borrowedString(nmr_settings_group_label($0)))
  }
}

extension SettingKey {
  /// The entry's index in the schema, from the C API: what the C calls take. A key the schema
  /// lacked would get an index every C call refuses (SchemaTests checks that none does).
  var index: UInt32 { Self.indexes[self] ?? .max }

  private static let indexes: [SettingKey: UInt32] = Dictionary(
    uniqueKeysWithValues: allCases.compactMap { key in
      let index = nmr_settings_index(key.rawValue)
      return index >= 0 ? (key, UInt32(index)) : nil
    })
}

extension SettingSpec {
  /// Entry `index`; nil past the end, or for a type or scope this build does not know.
  init?(index: UInt32) {
    var spec = nmr_setting_spec()
    guard nmr_settings_spec(index, &spec), let type = SettingType(spec.type),
      let scope = SettingScope(spec.scope)
    else { return nil }
    self.key = borrowedString(spec.key)
    self.label = borrowedString(spec.label)
    self.unit = borrowedString(spec.unit)
    self.group = borrowedString(nmr_settings_group_key(spec.group))
    self.type = type
    self.scope = scope
    self.inPresets = spec.preset
    self.minimum = spec.min
    self.maximum = spec.max
    self.step = spec.step
    self.defaultValue = spec.default_value
    self.defaultText = borrowedString(spec.default_text)
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
