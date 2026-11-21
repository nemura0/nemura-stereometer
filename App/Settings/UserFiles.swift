import Foundation
import NMRCoreC

/// A file the user keeps in Application Support, shared with the plugin: a preset or a colormap.
struct UserFile: Equatable, Sendable {
  /// The name shown: the file name without its extension, control characters and invalid UTF-8.
  let name: String
  let url: URL
}

extension UserFile {
  /// The files in a list the C API made, which this frees.
  static func adopt(_ list: OpaquePointer?) -> [UserFile] {
    guard let list else { return [] }
    defer { nmr_file_list_destroy(list) }
    return (0..<nmr_file_list_count(list)).map { index in
      UserFile(
        name: borrowedString(nmr_file_list_name(list, index)),
        url: URL(filePath: borrowedString(nmr_file_list_path(list, index))))
    }
  }
}

extension URL {
  /// The path the C API takes; "" (which it refuses) for a URL that is not a file URL or whose
  /// path holds a NUL, where C would stop and name another file.
  var cPath: String {
    guard isFileURL else { return "" }
    let text = path(percentEncoded: false)
    return text.hasNUL ? "" : text
  }

  /// A folder the C API named; nil for "" (no home folder).
  init?(folderFromC path: String?) {
    guard let path, !path.isEmpty else { return nil }
    self.init(filePath: path, directoryHint: .isDirectory)
  }
}

extension POSIXError {
  /// The error for an errno value from the C API (EIO when it gave none).
  init(errno value: Int32) {
    self.init(POSIXErrorCode(rawValue: value) ?? .EIO)
  }
}
