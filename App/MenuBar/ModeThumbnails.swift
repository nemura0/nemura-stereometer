import CoreGraphics
import Foundation
import Observation
import os

/// The mode picker's pictures for the current look, drawn on a background queue (Thumbnails).
/// A look that changes while drawing is drawn again once the current set is done.
@MainActor
@Observable
final class ModeThumbnails {
  private(set) var images: [MeterMode: CGImage] = [:]

  @ObservationIgnored private let renderer = Thumbnails()
  @ObservationIgnored private let queue = DispatchQueue(
    label: "thumbnails", qos: .userInitiated)
  @ObservationIgnored private var drawn: SettingValues?  // the look `images` show
  @ObservationIgnored private var drawing: SettingValues?
  @ObservationIgnored private var next: (look: SettingValues, side: Int, scale: Double)?
  @ObservationIgnored private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app", category: "thumbnails")

  /// Draws every mode in `values`' look, `side` points square, unless they show it already.
  func refresh(for values: SettingValues, side: Int, scale: Double) {
    let look = Thumbnails.look(values, mode: .goniometer)
    guard look != drawn, look != drawing else { return }
    guard drawing == nil else {
      next = (look, side, scale)
      return
    }
    guard let renderer else {
      Self.log.error("no Metal device: the modes have no thumbnails")
      return
    }
    drawing = look
    queue.async { [weak self] in
      var images: [MeterMode: CGImage] = [:]
      for mode in MeterMode.allCases {
        let modeLook = Thumbnails.look(look, mode: mode)
        images[mode] = renderer.image(of: modeLook, side: side, scale: scale)
      }
      let result = DrawnImages(images: images)
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.finished(look, result) }
      }
    }
  }

  private func finished(_ look: SettingValues, _ result: DrawnImages) {
    drawing = nil
    drawn = look
    if result.images.count < MeterMode.allCases.count {
      Self.log.error("some mode thumbnails could not be drawn")
    }
    images = result.images
    if let next {
      self.next = nil
      refresh(for: next.look, side: next.side, scale: next.scale)
    }
  }
}

/// Images made on the thumbnail queue and handed to the main thread, never touched again there.
private struct DrawnImages: @unchecked Sendable {
  let images: [MeterMode: CGImage]
}
