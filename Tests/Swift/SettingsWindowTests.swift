import AppKit
import Foundation
import NMRCoreC
import SwiftUI
import Testing

@testable import App

@MainActor
@Suite("Settings window")
struct SettingsWindowTests {
  private func model(presets: URL? = nil, colormaps: URL? = nil) -> SettingsModel {
    SettingsModel(
      store: SettingsStore(defaults: nil), presetFolder: presets, colormapFolder: colormaps)
  }

  @Test("The sidebar lists the schema's groups the app uses, each entry once")
  func groups() throws {
    let groups = model().groups
    #expect(groups.map(\.label) == [
      "Display", "Points & lines", "Response", "Level", "Color", "Meters", "Window",
      "Performance",
    ])
    let keys = groups.flatMap(\.keys)
    #expect(keys.count == Set(keys).count)
    #expect(Set(keys) == Set(SettingKey.allCases))
  }

  @Test("Long ranges slide on a log scale, others linearly, in the entry's steps")
  func sliders() throws {
    let trail = try #require(Schema.spec(.trailMs))
    #expect(SettingsModel.position(of: 5, in: trail) == 0)
    #expect(abs(SettingsModel.position(of: 2000, in: trail) - 1) < 1e-12)
    #expect(SettingsModel.position(of: 15, in: trail) < 0.25)  // Instant is not crammed at 0
    for value in [5.0, 15, 100, 1000, 2000] {
      let back = SettingsModel.value(at: SettingsModel.position(of: value, in: trail), in: trail)
      #expect(back == value)
    }
    let gain = try #require(Schema.spec(.gainDb))
    #expect(SettingsModel.position(of: -24, in: gain) == 0)
    #expect(SettingsModel.value(at: 0.5, in: gain) == 6)
    #expect(SettingsModel.value(at: 0.508, in: gain) == 6.5)  // 6.48 dB, in 0.5 dB steps
    #expect(SettingsModel.value(at: 2, in: gain) == 36)  // clamped
  }

  @Test("Values read with their units")
  func formatting() throws {
    func text(_ key: SettingKey, _ value: Double) throws -> String {
      SettingsModel.format(value, for: try #require(Schema.spec(key)))
    }
    #expect(try text(.trailMs, 15) == "15 ms")
    #expect(try text(.gainDb, 6) == "+6.0 dB")
    #expect(try text(.gainDb, -2.5) == "−2.5 dB")
    #expect(try text(.gainDb, 0) == "0.0 dB")
    #expect(try text(.density, 2) == "×2")
    #expect(try text(.brightness, 100) == "100 %")
    #expect(try text(.pointSize, 2) == "2.0 pt")
    #expect(try text(.logRangeDb, 48) == "48 dB")
    #expect(try text(.integrationMs, 1500) == "1500 ms")
  }

  @Test("Restoring a group's defaults leaves the other groups alone")
  func resetGroup() throws {
    let settings = model()
    settings.store.update { values in
      values.set(.gainDb, to: 9)
      values.set(.autoGain, choice: "fast")
      values.set(.glow, to: 12)
    }
    let level = try #require(settings.groups.first { $0.label == "Level" })
    settings.reset(level)
    #expect(settings.store.values.number(.gainDb) == 0)
    #expect(settings.store.values.choice(.autoGain) == "off")
    #expect(settings.store.values.number(.glow) == 12)
  }

  @Test("Colormaps: the original set, then the user's imported ones")
  func colormaps() async throws {
    let folder = try TemporaryFolder()
    let map = folder.url.appending(path: "Sunset.map")
    try "[rgb(255, 80, 0); 0] [rgb(255, 220, 120); 1]"
      .write(to: map, atomically: true, encoding: .utf8)
    let settings = model(colormaps: folder.url.appending(path: "Colormaps"))
    let imported = try await settings.importColormap(from: map)
    #expect(imported.label == "Sunset")
    #expect(settings.colormaps.prefix(Colormaps.builtins.count).map(\.label)
      == Colormaps.builtins.map(\.label))
    let user = try #require(settings.colormaps.last)
    #expect(user.label == "Sunset")
    settings.store.update { $0.set(.colormap, text: user.key) }
    #expect(settings.store.values.text(.colormap) == user.key)
  }

  @Test("Presets: save the current look, export it, import it back, delete it")
  func presets() async throws {
    let folder = try TemporaryFolder()
    let presets = folder.url.appending(path: "Presets")
    let settings = model(presets: presets)
    settings.store.update { $0.set(.glow, to: 44) }
    try await settings.saveCurrent(as: "Mine")
    #expect(settings.userPresets.map(\.name) == ["Mine"])

    let exported = folder.url.appending(path: "Shared.json")
    try await settings.export(settings.userPresets[0], to: exported)
    try await settings.delete(settings.userPresets[0])
    #expect(settings.userPresets.isEmpty)

    settings.store.update { $0.set(.glow, to: 0) }
    let imported = try await settings.importPreset(from: exported)
    #expect(imported.name == "Shared")
    #expect(settings.userPresets.map(\.name) == ["Shared"])
    settings.apply(imported)
    #expect(settings.store.values.number(.glow) == 44)
  }

  @Test("A file that is not a preset is not imported")
  func importRefusesOtherFiles() async throws {
    let folder = try TemporaryFolder()
    let bad = folder.url.appending(path: "notes.json")
    try "{\"hello\": 1}".write(to: bad, atomically: true, encoding: .utf8)
    let settings = model(presets: folder.url.appending(path: "Presets"))
    await #expect(throws: PresetError.self) { try await settings.importPreset(from: bad) }
    #expect(settings.userPresets.isEmpty)
  }

  @Test("The window's content lays out at the window's smallest size")
  func layout() {
    let host = NSHostingView(rootView: SettingsView(model: model()))
    host.frame = NSRect(origin: .zero, size: SettingsWindow.minimumSize)
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.width <= SettingsWindow.minimumSize.width)
  }

  @Test("Only settings that change the picture are enabled")
  func applies() {
    var values = SettingValues()
    values.set(.colorMode, choice: "solid")
    #expect(SettingsModel.applies(.solidColor, in: values))
    #expect(!SettingsModel.applies(.colormap, in: values))
    values.set(.colorMode, choice: "frequency")
    #expect(!SettingsModel.applies(.solidColor, in: values))
    #expect(SettingsModel.applies(.colormap, in: values))
    values.set(.mode, choice: "goniometer")
    #expect(!SettingsModel.applies(.logRangeDb, in: values))
    values.set(.mode, choice: "half_log")
    #expect(SettingsModel.applies(.logRangeDb, in: values))
    #expect(SettingsModel.applies(.gainDb, in: values))
  }

  @Test("Values show as many decimals as their step has")
  func decimals() {
    #expect(SettingsModel.decimalPlaces(forStep: 1) == 0)
    #expect(SettingsModel.decimalPlaces(forStep: 5) == 0)
    #expect(SettingsModel.decimalPlaces(forStep: 0.5) == 1)
    #expect(SettingsModel.decimalPlaces(forStep: 0.1) == 1)
    #expect(SettingsModel.decimalPlaces(forStep: 0.25) == 2)
    #expect(SettingsModel.decimalPlaces(forStep: 0.05) == 2)
    #expect(SettingsModel.decimalPlaces(forStep: 0) == 0)
  }

  @Test("A preset deleted elsewhere reports it is gone")
  func deleteMissing() async throws {
    let folder = try TemporaryFolder()
    let settings = model(presets: folder.url.appending(path: "Presets"))
    await #expect(throws: PresetError.missing) {
      try await settings.delete(Preset(name: "Nowhere", settings: SettingValues()))
    }
  }

  @Test("Errors read in words")
  func errorText() {
    #expect(PresetError.notWritten(POSIXError(.EACCES)).description.contains("ermission"))
    #expect(PresetError.missing.description.contains("no longer"))
  }
}
