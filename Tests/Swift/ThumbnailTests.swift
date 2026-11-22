import CoreGraphics
import Foundation
import Testing

@testable import App

@Suite("Mode thumbnails")
struct ThumbnailTests {
  @Test("A thumbnail is the meter's look at the asked size")
  func drawsAtSize() throws {
    guard let renderer = Thumbnails() else { return }  // no Metal device
    var settings = SettingValues()
    settings.set(.mode, choice: "goniometer")
    let image = try #require(renderer.image(of: settings, side: 48, scale: 2))
    #expect(image.width == 96)
    #expect(image.height == 96)
    #expect(image.alphaInfo == .premultipliedFirst)
  }

  @Test("Each mode draws a different picture")
  func modesDiffer() throws {
    guard let renderer = Thumbnails() else { return }
    let base = SettingValues()
    var seen: Set<Data> = []
    for mode in MeterMode.allCases {
      let image = try #require(renderer.image(of: Thumbnails.look(base, mode: mode), side: 40))
      let data = try #require(image.dataProvider?.data as Data?)
      seen.insert(data)
    }
    #expect(seen.count == MeterMode.allCases.count)
  }

  @Test("A mode's thumbnail keeps the look but has no meters or readouts")
  func look() {
    var base = SettingValues()
    base.set(.glow, to: 40)
    base.set(.meterReadouts, to: 1)
    let look = Thumbnails.look(base, mode: .lissajous)
    #expect(look.choice(.mode) == "lissajous")
    #expect(look.number(.glow) == 40)
    #expect(!look.flag(.correlationMeter))
    #expect(!look.flag(.balanceMeter))
    #expect(!look.flag(.meterReadouts))
  }

  @Test("Sizes the renderer cannot draw give no image")
  func badSizes() {
    guard let renderer = Thumbnails() else { return }
    #expect(renderer.image(of: SettingValues(), side: 0) == nil)
    #expect(renderer.image(of: SettingValues(), side: 40, scale: 0) == nil)
    #expect(renderer.image(of: SettingValues(), side: 2000, scale: 1) == nil)
  }

  @Test("Settings that change no pixels give the same thumbnail look")
  func windowSettingsLeaveTheLook() {
    var changed = SettingValues()
    for key in [SettingKey.clickThrough, .alwaysOnTop, .allSpaces, .hoverControls, .dockIcon] {
      changed.set(key, to: changed.flag(key) ? 0 : 1)
    }
    changed.set(.frameRate, choice: "30")
    #expect(Thumbnails.look(changed, mode: .goniometer)
      == Thumbnails.look(SettingValues(), mode: .goniometer))
  }

  @Test("A look changed and changed back while drawing ends with the current look shown")
  @MainActor
  func latestLookWins() async throws {
    guard Thumbnails() != nil else { return }
    let thumbnails = ModeThumbnails()
    let first = SettingValues()
    var second = first
    second.set(.glow, to: 60)
    thumbnails.refresh(for: first, side: 24, scale: 1)
    try await settle(thumbnails)
    thumbnails.refresh(for: second, side: 24, scale: 1)  // drawing now
    thumbnails.refresh(for: first, side: 24, scale: 1)   // and back, before it is done
    try await settle(thumbnails)
    #expect(thumbnails.shown == Thumbnails.look(first, mode: .goniometer))
  }

  @MainActor
  private func settle(_ thumbnails: ModeThumbnails) async throws {
    for _ in 0..<400 where thumbnails.isDrawing {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(!thumbnails.isDrawing)
  }
}
