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
}
