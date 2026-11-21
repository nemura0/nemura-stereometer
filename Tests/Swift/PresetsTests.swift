import Foundation
import NMRCoreC
import Testing

@testable import App

/// Factory presets and preset files, through the C API and Presets.
@Suite("Presets")
struct PresetsTests {
  @Test("The factory set: Mix, Stage, the original mode's preset and Classic")
  func factory() throws {
    let vendor = try configuredValue("NMR_VENDOR")
    #expect(Presets.factory.map(\.name) == ["Mix", "Stage", vendor, "Classic"])
    let stage = try #require(Presets.factory.first { $0.name == "Stage" })
    #expect(stage.settings.choice(.guides) == "off")
    let original = try #require(Presets.factory.first { $0.name == vendor })
    #expect(original.settings.choice(.mode) == "original")
  }

  @Test("Applying a preset changes the look and keeps the window behavior")
  func apply() throws {
    var current = SettingValues()
    current.set(.clickThrough, to: 1)
    current.set(.gainDb, to: 12)
    let classic = try #require(Presets.factory.first { $0.name == "Classic" })
    let applied = current.applying(classic.settings)
    #expect(applied.choice(.drawStyle) == "lines")
    #expect(applied.color(.solidColor) == 0x66FF_99FF)
    #expect(applied.flag(.clickThrough))  // presets do not store window behavior
    #expect(applied.number(.gainDb) == 0)  // presets store the gain: Classic keeps the default
    #expect(current.number(.gainDb) == 12)
  }

  @Test("Saved presets are listed, loaded under their file's name and removed")
  func saveLoadRemove() throws {
    let temporary = try TemporaryFolder()
    let folder = temporary.url.appending(path: "Presets")
    var settings = SettingValues()
    settings.set(.mode, choice: "lissajous")
    settings.set(.dockIcon, to: 1)  // not stored in presets

    let saved = try Presets.save(Preset(name: "Late: Night", settings: settings), in: folder)
    #expect(saved.lastPathComponent == "Late- Night.json")
    #expect(Presets.fileName(for: "Late: Night") == "Late- Night.json")
    let listed = Presets.list(in: folder)
    #expect(listed.map(\.name) == ["Late- Night"])
    #expect(listed.map(\.url.cPath) == [saved.cPath])

    let (preset, report) = Presets.load(saved)
    #expect(report.status == .ok)
    #expect(preset?.name == "Late- Night")
    #expect(preset?.settings.choice(.mode) == "lissajous")
    #expect(preset?.settings.flag(.dockIcon) == false)

    try Presets.remove(saved)
    #expect(Presets.list(in: folder).isEmpty)
    #expect(throws: POSIXError(.ENOENT)) { try Presets.remove(saved) }
  }

  @Test("Exported JSON loads back as the same preset, named after its file")
  func export() throws {
    let temporary = try TemporaryFolder()
    var settings = SettingValues()
    settings.set(.glow, to: 33)
    let json = Presets.json(for: Preset(name: "Glow", settings: settings))
    #expect(json.contains(#""name": "Glow""#))
    let file = temporary.url.appending(path: "Exported.json")
    try json.write(to: file, atomically: true, encoding: .utf8)
    let (preset, report) = Presets.load(file)
    #expect(report.status == .ok)
    #expect(preset?.name == "Exported")
    #expect(preset?.settings.number(.glow) == 33)
  }

  @Test("A NUL in a name is dropped, like other control characters")
  func namesWithNUL() throws {
    let temporary = try TemporaryFolder()
    let preset = Preset(name: "Mi\0x", settings: SettingValues())
    #expect(Presets.fileName(for: preset.name) == "Mix.json")
    #expect(try Presets.save(preset, in: temporary.url).lastPathComponent == "Mix.json")
    #expect(Presets.json(for: preset).contains(#""name": "Mix""#))
  }

  @Test("Unreadable files and unwritable folders fail; only preset files are removed")
  func failures() throws {
    let temporary = try TemporaryFolder()
    let missing = Presets.load(temporary.url.appending(path: "Missing.json"))
    #expect(missing.preset == nil)
    #expect(missing.report.status == .unreadable)
    let large = temporary.url.appending(path: "Large.json")
    try String(repeating: " ", count: 256 * 1024 + 1).write(
      to: large, atomically: true, encoding: .utf8)
    let tooLarge = Presets.load(large)
    #expect(tooLarge.preset == nil)
    #expect(tooLarge.report.status == .tooLarge)

    let file = temporary.url.appending(path: "file")
    try "".write(to: file, atomically: true, encoding: .utf8)
    let preset = Preset(name: "X", settings: SettingValues())
    #expect(throws: POSIXError(.ENOTDIR)) {
      try Presets.save(preset, in: file.appending(path: "Presets"))
    }
    let web = try #require(URL(string: "https://example.com\(temporary.url.path())Presets/"))
    #expect(throws: POSIXError(.EINVAL)) { try Presets.save(preset, in: web) }  // not a file URL
    let cut = temporary.url.appending(path: "Cut")
    #expect(throws: POSIXError(.EINVAL)) {  // C would stop at the NUL and save into Cut
      try Presets.save(preset, in: URL(filePath: cut.cPath + "\0/Presets"))
    }
    #expect(!FileManager.default.fileExists(atPath: cut.cPath))

    let folder = temporary.url.appending(path: "Folder.json")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    #expect(throws: POSIXError(.EPERM)) { try Presets.remove(folder) }  // never a folder
    #expect(FileManager.default.fileExists(atPath: folder.cPath))
    let notes = temporary.url.appending(path: "Notes.txt")
    try "keep".write(to: notes, atomically: true, encoding: .utf8)
    #expect(throws: POSIXError(.EINVAL)) { try Presets.remove(notes) }  // never another file
    #expect(FileManager.default.fileExists(atPath: notes.cPath))
  }

  @Test("The preset C calls refuse missing arguments and relative paths")
  func cEdges() throws {
    let count = nmr_presets_factory_count()
    #expect(nmr_presets_factory_name(count) == nil)
    #expect(nmr_presets_factory_settings(count) == nil)
    #expect(nmr_presets_apply(nil, nil) == nil)

    let empty = try #require(nmr_presets_list(nil))
    #expect(nmr_file_list_count(empty) == 0)
    #expect(nmr_file_list_name(empty, 0) == nil)
    #expect(nmr_file_list_path(empty, 0) == nil)
    nmr_file_list_destroy(empty)
    nmr_file_list_destroy(nil)
    #expect(nmr_file_list_count(nil) == 0)
    #expect(UserFile.adopt(nmr_presets_list("relative")).isEmpty)

    var name: UnsafeMutablePointer<CChar>?
    var report = nmr_json_report()
    #expect(nmr_presets_load("relative.json", &name, &report) == nil)
    #expect(name == nil)
    #expect(report.status == NMR_JSON_UNREADABLE)
    #expect(nmr_presets_load(nil, nil, nil) == nil)

    // Swift file URLs are always absolute, so relative paths are refused here, in the C calls.
    var error: Int32 = 0
    let settings = try #require(nmr_settings_create())
    defer { nmr_settings_destroy(settings) }
    #expect(nmr_presets_save("relative/Presets", "X", settings, &error) == nil)
    #expect(error == EINVAL)
    let temporary = try TemporaryFolder()
    error = -1
    let saved = try #require(
      takenString(nmr_presets_save(temporary.url.cPath, "X", settings, &error)))
    #expect(error == 0)
    error = -1
    #expect(nmr_presets_remove(saved, &error))
    #expect(error == 0)
    error = 0
    #expect(nmr_presets_save("/nonexistent-nmr", "X", nil, &error) == nil)
    #expect(error == EINVAL)
    #expect(nmr_presets_save(nil, "X", nil, nil) == nil)
    #expect(!nmr_presets_remove("relative.json", &error))
    #expect(error == EINVAL)
    #expect(nmr_presets_file_name(nil) == nil)
    #expect(nmr_presets_encode(nil, nil) == nil)
    #expect(Presets.directory?.cPath.hasSuffix("/Presets/") == true)
  }
}
