import NMRCoreC
import Testing

@testable import App

/// The Swift side of the settings schema agrees with the C++ schema behind the C API.
@Suite("Settings schema")
struct SchemaTests {
  @Test("The C API hands out every entry, and nothing past the end")
  func readsEveryEntry() throws {
    let count = nmr_settings_count()
    #expect(count > 0)
    #expect(Schema.entries.count == Int(count))
    #expect(Set(Schema.entries.map(\.key)).count == Schema.entries.count)
    for entry in Schema.entries {
      #expect(!entry.label.isEmpty, "\(entry.key)")
      #expect(!entry.group.isEmpty, "\(entry.key)")
      #expect(entry.minimum <= entry.maximum, "\(entry.key)")
      #expect(entry.type == .choice ? entry.choices.count >= 2 : entry.choices.isEmpty)
    }

    var spec = nmr_setting_spec()
    #expect(!nmr_settings_spec(count, &spec))
    #expect(!nmr_settings_spec(0, nil))
    #expect(nmr_settings_choice_key(count, 0) == nil)
    #expect(nmr_settings_group_key(nmr_settings_group_count()) == nil)
    let mode = try #require(Schema.spec(.mode))
    #expect(nmr_settings_choice_key(0, UInt32(mode.choices.count)) == nil)
    #expect(!nmr_settings_stop(0, 0, nil, nil))
  }

  @Test("Every Swift key is in the schema with the same type, and is not plugin-only")
  func swiftKeysAreInTheSchema() throws {
    for key in SettingKey.allCases {
      let spec = try #require(Schema.spec(key), "\(key.rawValue)")
      #expect(spec.type == key.type, "\(key.rawValue)")
      #expect(spec.scope != .plugin, "\(key.rawValue)")
    }
  }

  @Test("Every schema entry the app uses has a Swift key")
  func schemaEntriesHaveSwiftKeys() throws {
    try #require(Schema.entries.contains { $0.scope == .plugin })
    for entry in Schema.entries where entry.scope != .plugin {
      #expect(SettingKey(rawValue: entry.key) != nil, "\(entry.key)")
    }
    for entry in Schema.entries where entry.scope == .plugin {
      #expect(SettingKey(rawValue: entry.key) == nil, "\(entry.key)")
    }
  }

  @Test("Swift choice cases are the schema's choices, in order")
  func choicesAgree() throws {
    for key in SettingKey.allCases {
      let spec = try #require(Schema.spec(key), "\(key.rawValue)")
      #expect(key.choiceKeys == spec.choices.map(\.key), "\(key.rawValue)")
    }
  }

  @Test("The schema's details come through: units, ranges, defaults, stops")
  func detailsComeThrough() throws {
    let gain = try #require(Schema.spec(.gainDb))
    #expect(gain.unit == "dB")
    #expect(gain.minimum == -24)
    #expect(gain.maximum == 36)
    #expect(gain.group == "level")
    #expect(gain.inPresets)

    let trail = try #require(Schema.spec(.trailMs))
    #expect(trail.stops.map(\.label) == ["Instant", "Fast", "Medium", "Slow", "Very slow"])
    #expect(trail.defaultValue == 100)

    let colormap = try #require(Schema.spec(.colormap))
    #expect(colormap.defaultText == "iris")
    #expect(colormap.maxLength == 63)

    let dock = try #require(Schema.spec(.dockIcon))
    #expect(dock.scope == .app)
    #expect(!dock.inPresets)

    let mode = try #require(Schema.spec(.mode))
    #expect(mode.choices.first == SettingSpec.Choice(key: "goniometer", label: "Goniometer"))
    #expect(mode.choices.last?.key == "original")
    #expect(mode.choices.last?.label.isEmpty == false)
  }
}
