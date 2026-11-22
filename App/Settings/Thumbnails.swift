import CoreGraphics
import Foundation
import NMRCoreC

/// The mode picker's thumbnails: the meter's look drawn offscreen by the meter's own renderer
/// from a built-in test signal (nmr/thumbnail.h). Drawing waits for the GPU: call image(of:)
/// off the main thread, one thread at a time.
final class Thumbnails: @unchecked Sendable {  // one thread at a time, as documented
  private let handle: OpaquePointer

  /// Nil without a Metal device.
  init?() {
    guard let handle = nmr_thumbnailer_create() else { return nil }
    self.handle = handle
  }

  deinit { nmr_thumbnailer_destroy(handle) }

  /// `settings` drawn `side` points square at `scale` pixels per point (a user colormap is read
  /// from its file); nil for a size it cannot draw (over 1024 pixels) or a failure.
  func image(of settings: SettingValues, side: Int, scale: Double = 1) -> CGImage? {
    let pixels = (Double(side) * scale).rounded()
    guard side > 0, scale > 0, pixels >= 1, pixels <= 1024 else { return nil }
    let width = Int(pixels)
    let table = Colormaps.table(for: settings.text(.colormap), userFolder: Colormaps.directory)
    var bgra = [UInt8](repeating: 0, count: width * width * 4)
    let drawn = settings.withHandle { settingsHandle in
      table.rgba.withUnsafeBufferPointer { rgba in
        bgra.withUnsafeMutableBufferPointer { out in
          nmr_thumbnailer_render(
            handle, settingsHandle, rgba.baseAddress, UInt32(width), UInt32(width), Float(scale),
            out.baseAddress)
        }
      }
    }
    guard drawn, let provider = CGDataProvider(data: Data(bgra) as CFData),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    let info = CGBitmapInfo.byteOrder32Little.rawValue
      | CGImageAlphaInfo.premultipliedFirst.rawValue
    return CGImage(
      width: width, height: width, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
      shouldInterpolate: true, intent: .defaultIntent)
  }

  /// What a mode's thumbnail draws: the current look in `mode`, without the meters and readouts
  /// (too small to read at thumbnail size).
  static func look(_ settings: SettingValues, mode: MeterMode) -> SettingValues {
    var look = settings
    look.set(.mode, choice: mode.rawValue)
    for key in [SettingKey.correlationMeter, .balanceMeter, .meterReadouts] { look.set(key, to: 0) }
    return look
  }
}
