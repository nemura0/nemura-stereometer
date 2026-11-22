import AppKit
import Foundation
import SwiftUI
import Testing

@testable import App

@MainActor
@Suite("Menu-bar popover")
struct MeterMenuTests {
  private func model(_ folder: URL? = nil) -> MeterMenuModel {
    MeterMenuModel(store: SettingsStore(defaults: nil), presetFolder: folder)
  }

  @Test("The mode picker changes the meter's mode")
  func mode() {
    let menu = model()
    #expect(menu.mode == .original)
    menu.mode = .lissajous
    #expect(menu.store.values.choice(.mode) == "lissajous")
    #expect(menu.modeLabel(.lissajous) == Schema.spec(.mode)?.choices[4].label)
  }

  @Test("The preset shown is the one the look matches, else Custom")
  func presetTitle() {
    let menu = model()
    #expect(menu.presetTitle == "NEMURA")
    menu.choosePreset(menu.presets.first { $0.name == "Mix" }!)
    #expect(menu.presetTitle == "Mix")
    menu.store.update { $0.set(.gainDb, to: 12) }
    #expect(menu.presetTitle == MeterMenuModel.custom)
  }

  @Test("User presets follow the factory ones, from the preset folder")
  func userPresets() throws {
    let folder = try TemporaryFolder()
    var look = SettingValues()
    look.set(.glow, to: 33)
    _ = try Presets.save(Preset(name: "Late Night", settings: look), in: folder.url)
    let menu = model(folder.url)
    #expect(menu.presets.map(\.name) == Presets.factory.map(\.name))
    #expect(menu.userPresets.map(\.name) == ["Late Night"])
    menu.choosePreset(menu.userPresets[0])
    #expect(menu.store.values.number(.glow) == 33)
    #expect(menu.presetTitle == "Late Night")
  }

  @Test("Opacity is the background's, in percent; click-through toggles")
  func opacityAndClickThrough() {
    let menu = model()
    menu.opacity = 40
    #expect(menu.store.values.number(.backgroundOpacity) == 40)
    #expect(menu.opacity == 40)
    menu.opacity = 140
    #expect(menu.opacity == 100)
    #expect(!menu.clickThrough)
    menu.clickThrough = true
    #expect(menu.store.values.flag(.clickThrough))
  }

  @Test("The source line says what the capture does")
  func source() {
    let menu = model()
    #expect(menu.sourceStatus == "Starting…")
    var state = CaptureState()
    state.phase = .capturing(sampleRate: 48000, channels: 2)
    menu.capture = state
    #expect(menu.sourceStatus == "48 kHz, stereo")
    state.phase = .capturing(sampleRate: 44100, channels: 1)
    menu.capture = state
    #expect(menu.sourceStatus == "44.1 kHz, mono")
    state.signal = .silenceWhilePlaying
    menu.capture = state
    #expect(menu.sourceStatus == "Only silence arrives")
    state.phase = .failed(step: "tap", status: -50)
    menu.capture = state
    #expect(menu.sourceStatus == "Not capturing (error -50)")
  }

  @Test("The popover lays out at its width, short enough for a small laptop screen")
  func layout() {
    let view = MeterMenuView(
      model: model(), thumbnails: ModeThumbnails(), scale: 2, showSettings: {}, quit: {})
    let size = NSHostingController(rootView: view).view.fittingSize
    #expect(size.width == MeterMenuView.width)
    #expect(size.height > 300)
    #expect(size.height < 620)
  }

  @Test("The menu-bar icon is a template the menu bar can tint")
  func icon() {
    #expect(MenuBarIcon.image.isTemplate)
    #expect(MenuBarIcon.image.size == NSSize(width: 18, height: 18))
    #expect(MenuBarIcon.image.accessibilityDescription?.isEmpty == false)
  }
}
