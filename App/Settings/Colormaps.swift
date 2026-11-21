import Foundation
import NMRCoreC

/// A built-in colormap: the key the colormap setting stores and the label the UI shows.
struct Colormap: Equatable, Sendable {
  let key: String
  let label: String
}

/// What reading a `.map` file found.
struct ColormapReport: Equatable, Sendable {
  enum Status: Equatable, Sendable {
    case ok
    /// Nothing but malformed entries.
    case noStops
    /// Over 64 KiB.
    case tooLarge
    /// Missing, not a regular file, or unreadable.
    case unreadable
  }

  var status: Status
  /// Bracketed entries that are not stops, and stops past 256.
  var skipped: Int
  /// Components above 255 or positions above 1, clamped.
  var adjusted: Int
}

extension ColormapReport {
  init(_ report: nmr_colormap_report) {
    let status: Status =
      switch report.status {
      case NMR_COLORMAP_OK: .ok
      case NMR_COLORMAP_NO_STOPS: .noStops
      case NMR_COLORMAP_TOO_LARGE: .tooLarge
      default: .unreadable
      }
    self.init(status: status, skipped: Int(report.skipped), adjusted: Int(report.adjusted))
  }
}

/// Why a `.map` file was not imported.
enum ColormapImportError: Error, Equatable {
  /// The file is missing, not a regular file, or cannot be read.
  case unreadable
  /// The file holds nothing but malformed entries or is over 64 KiB: the report's status says
  /// which.
  case notAColormap(ColormapReport)
  /// The colormap folder could not be written.
  case notWritten(POSIXError)
}

/// The original colormaps and the user's colormaps imported from MiniMeters `.map` files.
enum Colormaps {
  static let tableSize = Int(NMR_COLORMAP_TABLE_SIZE)

  /// Iris (the default), Chrome, Bloodmoon, Phosphor, Aurora and Glacier.
  static let builtins: [Colormap] = (0..<nmr_colormaps_builtin_count()).map { index in
    Colormap(
      key: borrowedString(nmr_colormaps_builtin_key(index)),
      label: borrowedString(nmr_colormaps_builtin_label(index)))
  }

  /// The user's colormap folder (not created); nil without a home folder.
  static let directory = URL(folderFromC: takenString(nmr_colormaps_directory()))

  /// The `.map` files in `folder`, sorted by name ignoring case.
  static func list(in folder: URL) -> [UserFile] {
    UserFile.adopt(nmr_colormaps_list(folder.cPath))
  }

  /// The setting key of the user colormap listed as `name`; "" for a name no listed file has
  /// (one holding a NUL).
  static func key(forUserColormap name: String) -> String {
    guard !name.hasNUL else { return "" }
    return takenString(nmr_colormaps_user_key(name)) ?? ""
  }

  /// The colormap a setting key names as `tableSize` RGBA colors (straight alpha; entry i at
  /// t = i / 255), and whether the key named one: the table is Iris otherwise. User colormaps
  /// come from `userFolder`. A user key reads a file: call it when the setting changes.
  static func table(for key: String, userFolder: URL?) -> (rgba: [UInt8], found: Bool) {
    var rgba = [UInt8](repeating: 0, count: tableSize * 4)
    let found = rgba.withUnsafeMutableBufferPointer { table in
      nmr_colormaps_table(key, userFolder?.cPath ?? "", table.baseAddress)
    }
    return (rgba, found)
  }

  /// Imports a `.map` file into `folder` (created if needed) under its own name, replacing a
  /// colormap of that name. Blocks until the file reaches the drive: call it off the main thread.
  static func importMap(_ source: URL, into folder: URL) throws(ColormapImportError) -> (
    file: URL, report: ColormapReport
  ) {
    let from = source.cPath
    guard !from.isEmpty else { throw .unreadable }
    var report = nmr_colormap_report()
    var error: Int32 = 0
    let path = takenString(nmr_colormaps_import(folder.cPath, from, &report, &error))
    let found = ColormapReport(report)
    guard let path else {
      switch found.status {
      case .ok: throw .notWritten(POSIXError(errno: error))
      case .unreadable: throw .unreadable
      case .noStops, .tooLarge: throw .notAColormap(found)
      }
    }
    return (URL(filePath: path), found)
  }

  /// Deletes a colormap file: one ending in .map in any case, never a folder or another file.
  static func remove(_ file: URL) throws(POSIXError) {
    var error: Int32 = 0
    guard nmr_colormaps_remove(file.cPath, &error) else { throw POSIXError(errno: error) }
  }
}
