import CoreGraphics
import Foundation
import Observation
import os

/// The mode picker's pictures for the current look, drawn on a background queue (Thumbnails).
/// Only the latest look asked for is drawn next: one that changes while a set is drawing is
/// drawn once that set is done, unless it changed back to the set being drawn.
@MainActor
@Observable
final class ModeThumbnails {
  private(set) var images: [MeterMode: CGImage] = [:]

  @ObservationIgnored private let renderer = Thumbnails()
  @ObservationIgnored private let queue = DispatchQueue(
    label: "thumbnails", qos: .userInitiated)
  /// The look `images` show.
  @ObservationIgnored private(set) var shown: SettingValues?
  @ObservationIgnored private var drawing: SettingValues?
  @ObservationIgnored private var wanted: Request?
  @ObservationIgnored private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app", category: "thumbnails")

  private struct Request {
    let look: SettingValues
    let side: Int
    let scale: Double
  }

  init() {
    if renderer == nil { Self.log.error("no Metal device: the modes have no thumbnails") }
  }

  var isDrawing: Bool { drawing != nil }

  /// Draws every mode in `values`' look, `side` points square, unless they show it already.
  func refresh(for values: SettingValues, side: Int, scale: Double) {
    wanted = Request(look: Thumbnails.look(values, mode: .goniometer), side: side, scale: scale)
    drawWanted()
  }

  private func drawWanted() {
    guard drawing == nil, let request = wanted, let renderer else { return }
    wanted = nil
    guard request.look != shown else { return }
    drawing = request.look
    queue.async { [weak self] in
      var images: [MeterMode: CGImage] = [:]
      for mode in MeterMode.allCases {
        let modeLook = Thumbnails.look(request.look, mode: mode)
        images[mode] = renderer.image(of: modeLook, side: request.side, scale: request.scale)
      }
      let result = DrawnImages(images: images)
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.finished(request.look, result) }
      }
    }
  }

  private func finished(_ look: SettingValues, _ result: DrawnImages) {
    drawing = nil
    shown = look
    if result.images.count < MeterMode.allCases.count {
      Self.log.error("some mode thumbnails could not be drawn")
    }
    images = result.images
    drawWanted()
  }
}

/// Images made on the thumbnail queue and handed to the main thread, never touched again there.
private struct DrawnImages: @unchecked Sendable {
  let images: [MeterMode: CGImage]
}
