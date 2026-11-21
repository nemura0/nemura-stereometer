import NMRCoreC

/// A static or borrowed C string from the C API, copied; "" for NULL.
func borrowedString(_ text: UnsafePointer<CChar>?) -> String {
  text.map { String(cString: $0) } ?? ""
}

/// A string the C API allocated for the caller, copied and freed; nil for NULL.
func takenString(_ text: UnsafeMutablePointer<CChar>?) -> String? {
  guard let text else { return nil }
  defer { nmr_string_free(text) }
  return String(cString: text)
}

extension String {
  /// Whether this holds a NUL: C would see only what comes before the first one.
  var hasNUL: Bool { utf8.contains(0) }

  /// This string without its NUL characters, all of which C sees.
  var withoutNUL: String { String(unicodeScalars.filter { $0 != "\0" }) }
}
