import NMRCoreC
import Testing

@testable import App

/// Setting values held by the C++ core, through the C API and SettingValues.
@Suite("Setting values")
struct SettingValuesTests {
  @Test("Every Swift key knows its schema index")
  func keysHaveIndexes() throws {
    for key in SettingKey.allCases {
      try #require(key.index < nmr_settings_count(), "\(key.rawValue)")
      #expect(Schema.entries[Int(key.index)].key == key.rawValue)
    }
  }

  @Test("New values hold every schema default")
  func defaults() throws {
    let values = SettingValues()
    for key in SettingKey.allCases {
      let spec = try #require(Schema.spec(key))
      if key.type == .text {
        #expect(values.text(key) == spec.defaultText, "\(key.rawValue)")
        #expect(values.number(key) == 0, "\(key.rawValue)")
      } else {
        #expect(values.number(key) == spec.defaultValue, "\(key.rawValue)")
        #expect(values.text(key) == "", "\(key.rawValue)")
      }
    }
    #expect(values.choice(.mode) == "goniometer")
    #expect(values.choice(.gainDb) == "")
    #expect(values.color(.pointSize) == 0)  // not a color
    #expect(values.color(.solidColor) == 0x8993_FFFF)
    #expect(values.flag(.alwaysOnTop))
  }

  @Test("Setters keep every value valid and say what they did")
  func setters() {
    var values = SettingValues()
    #expect(values.set(.gainDb, to: 6) == .set)
    #expect(values.number(.gainDb) == 6)
    #expect(values.set(.gainDb, to: 99) == .adjusted)
    #expect(values.number(.gainDb) == 36)
    #expect(values.set(.gainDb, to: .nan) == .rejected)
    #expect(values.number(.gainDb) == 36)
    #expect(values.set(.density, to: 2.6) == .adjusted)  // ints are rounded
    #expect(values.number(.density) == 3)
    #expect(values.set(.dockIcon, to: 1) == .set)
    #expect(values.flag(.dockIcon))
    #expect(values.set(.dockIcon, to: 0.5) == .rejected)
    #expect(values.set(.solidColor, to: 0x1122_3344) == .set)
    #expect(values.color(.solidColor) == 0x1122_3344)

    #expect(values.set(.mode, choice: "lissajous") == .set)
    #expect(values.choice(.mode) == "lissajous")
    #expect(values.set(.mode, choice: "nope") == .rejected)
    #expect(values.set(.mode, text: "half") == .rejected)
    #expect(values.set(.mode, choice: "half\0") == .rejected)  // C would see "half"
    #expect(values.choice(.mode) == "lissajous")

    #expect(values.set(.colormap, text: "user:Sunset Glow") == .set)
    #expect(values.text(.colormap) == "user:Sunset Glow")
    #expect(values.set(.colormap, text: "bad\u{1}") == .rejected)
    #expect(values.set(.colormap, text: String(repeating: "x", count: 257)) == .rejected)
    #expect(values.set(.colormap, text: "user:a\0b") == .rejected)  // a control character
    #expect(values.set(.colormap, to: 1) == .rejected)
    #expect(values.text(.colormap) == "user:Sunset Glow")

    values.reset(.gainDb)
    values.reset(.colormap)
    #expect(values.number(.gainDb) == 0)
    #expect(values.text(.colormap) == "iris")
  }

  @Test("Copies change independently and compare by value")
  func valueSemantics() {
    var a = SettingValues()
    let b = a
    #expect(a == b)
    a.set(.glow, to: 50)
    #expect(a != b)
    #expect(b.number(.glow) == 0)
    var c = b
    c.set(.glow, to: 50)
    #expect(a == c)  // two handles, the same values
    c.set(.colormap, text: "chrome")
    #expect(a != c)
    #expect(b.text(.colormap) == "iris")
  }

  @Test("JSON keeps every value")
  func jsonRoundTrip() {
    var values = SettingValues()
    values.set(.mode, choice: "half_log")
    values.set(.gainDb, to: -7.5)
    values.set(.colormap, text: "user:Sunset Glow")
    values.set(.clickThrough, to: 1)
    values.set(.backgroundColor, to: 0x0102_0304)
    let json = values.json
    #expect(json.contains(#""version": 1"#))
    let (decoded, report) = SettingValues.decode(json: json)
    #expect(decoded == values)
    #expect(
      report
        == SettingsReport(
          status: .ok, version: 1, newer: false, ignored: 0, invalid: 0, adjusted: 0))
  }

  @Test("Decoding untrusted JSON gives usable settings and says what it found")
  func jsonUntrusted() {
    let notJSON = SettingValues.decode(json: "{ nope")
    #expect(notJSON.values == SettingValues())
    #expect(notJSON.report.status == .notJSON)
    #expect(SettingValues.decode(json: "").report.status == .notJSON)
    #expect(SettingValues.decode(json: "[1, 2]").report.status == .notSettings)

    let partial = SettingValues.decode(
      json: #"""
        {"version": 1, "settings": {"gain_db": 99, "mode": "nope", "draw_style": 1,
         "what": 1, "who": 2, "why": 3, "glow": 20}}
        """#)
    #expect(
      partial.report
        == SettingsReport(
          status: .ok, version: 1, newer: false, ignored: 3, invalid: 2, adjusted: 1))
    #expect(partial.values.number(.gainDb) == 36)
    #expect(partial.values.choice(.mode) == "goniometer")
    #expect(partial.values.number(.glow) == 20)

    let newer = SettingValues.decode(json: #"{"version": 7, "settings": {"glow": 5}}"#)
    #expect(newer.report.status == .ok)
    #expect(newer.report.newer)
    #expect(newer.report.version == 7)
    #expect(newer.values.number(.glow) == 5)
    let huge = SettingValues.decode(json: String(repeating: " ", count: 256 * 1024 + 1))
    #expect(huge.report.status == .tooLarge)
  }

  @Test("The JSON calls take a missing handle, text or report")
  func jsonCEdges() throws {
    #expect(nmr_settings_encode(nil) == nil)
    nmr_string_free(nil)
    let defaults = try #require(nmr_settings_decode(nil, 0, nil))
    defer { nmr_settings_destroy(defaults) }
    var report = nmr_json_report()
    let other = try #require(nmr_settings_decode(nil, 16, &report))  // no text: nothing is read
    defer { nmr_settings_destroy(other) }
    #expect(report.status == NMR_JSON_NOT_JSON)
    #expect(nmr_settings_equal(defaults, other))
    let fresh = try #require(nmr_settings_create())
    defer { nmr_settings_destroy(fresh) }
    #expect(nmr_settings_equal(defaults, fresh))

    // Only `length` bytes are read: the text may go on past them.
    let text = #"{"version": 1, "settings": {"glow": 5}} and more"#
    let length = text.utf8.count - " and more".utf8.count
    let read = try #require(nmr_settings_decode(text, length, &report))
    defer { nmr_settings_destroy(read) }
    #expect(report.status == NMR_JSON_OK)
    #expect(nmr_settings_number(read, SettingKey.glow.index) == 5)
  }

  @Test("The C calls refuse a missing handle, a bad index and missing strings")
  func cEdges() throws {
    let count = nmr_settings_count()
    #expect(nmr_settings_index("mode") == 0)
    #expect(nmr_settings_index("nope") == -1)
    #expect(nmr_settings_index(nil) == -1)
    #expect(nmr_settings_number(nil, 0) == 0)
    #expect(nmr_settings_text(nil, 0) == nil)
    #expect(nmr_settings_set_number(nil, 0, 1) == NMR_CHANGE_REJECTED)
    #expect(nmr_settings_set_choice(nil, 0, "half") == NMR_CHANGE_REJECTED)
    #expect(nmr_settings_set_text(nil, 0, "x") == NMR_CHANGE_REJECTED)
    #expect(nmr_settings_copy(nil) == nil)
    #expect(!nmr_settings_equal(nil, nil))
    nmr_settings_destroy(nil)
    nmr_settings_reset(nil, 0)

    let handle = try #require(nmr_settings_create())
    defer { nmr_settings_destroy(handle) }
    let colormap = UInt32(nmr_settings_index("colormap"))
    #expect(nmr_settings_number(handle, count) == 0)
    #expect(nmr_settings_text(handle, count) == nil)
    #expect(nmr_settings_set_number(handle, count, 0) == NMR_CHANGE_REJECTED)
    #expect(nmr_settings_set_choice(handle, 0, nil) == NMR_CHANGE_REJECTED)
    #expect(nmr_settings_set_text(handle, colormap, nil) == NMR_CHANGE_REJECTED)
    nmr_settings_reset(handle, count)
    #expect(String(cString: try #require(nmr_settings_text(handle, 0))) == "")  // mode: no text
    #expect(String(cString: try #require(nmr_settings_text(handle, colormap))) == "iris")
    #expect(!nmr_settings_equal(handle, nil))
    #expect(nmr_settings_equal(handle, handle))
  }
}
