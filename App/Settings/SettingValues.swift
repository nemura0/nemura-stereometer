import NMRCoreC

/// What a setter did with a value.
enum SettingChange: Equatable, Sendable {
  case set
  /// Clamped into the range or rounded to an integer.
  case adjusted
  /// The wrong type, NaN, not one of the choices or a string holding a NUL: the old value stays.
  case rejected

  init(_ change: nmr_change) {
    switch change {
    case NMR_CHANGE_SET: self = .set
    case NMR_CHANGE_ADJUSTED: self = .adjusted
    default: self = .rejected
    }
  }
}

/// A value for every setting in the shared schema, each kept valid by the C++ core: setters
/// clamp, round or refuse what they are given. A value type: copies change independently.
struct SettingValues: Equatable, Sendable {
  private var storage: Storage

  /// Every setting at its default.
  init() {
    storage = Storage(nmr_settings_create())
  }

  /// Takes ownership of a handle the C API created.
  init(adopting handle: OpaquePointer?) {
    storage = Storage(handle)
  }

  /// Bool 0/1, int, float, choice index or color; 0 for text.
  func number(_ key: SettingKey) -> Double {
    nmr_settings_number(storage.handle, key.index)
  }

  func flag(_ key: SettingKey) -> Bool { number(key) != 0 }

  /// 0xRRGGBBAA; 0 for other types.
  func color(_ key: SettingKey) -> UInt32 {
    guard key.type == .color else { return 0 }
    return UInt32(number(key))  // the core keeps colors within 0...0xFFFFFFFF
  }

  /// The key of the chosen choice; "" for other types.
  func choice(_ key: SettingKey) -> String {
    guard key.type == .choice else { return "" }
    return borrowedString(nmr_settings_choice_key(key.index, UInt32(number(key))))
  }

  /// "" for types other than text.
  func text(_ key: SettingKey) -> String {
    borrowedString(nmr_settings_text(storage.handle, key.index))
  }

  @discardableResult
  mutating func set(_ key: SettingKey, to value: Double) -> SettingChange {
    SettingChange(nmr_settings_set_number(uniqueHandle(), key.index, value))
  }

  @discardableResult
  mutating func set(_ key: SettingKey, choice: String) -> SettingChange {
    guard !choice.hasNUL else { return .rejected }
    return SettingChange(nmr_settings_set_choice(uniqueHandle(), key.index, choice))
  }

  /// Valid UTF-8 within the entry's maximum length, without control characters.
  @discardableResult
  mutating func set(_ key: SettingKey, text: String) -> SettingChange {
    guard !text.hasNUL else { return .rejected }
    return SettingChange(nmr_settings_set_text(uniqueHandle(), key.index, text))
  }

  mutating func reset(_ key: SettingKey) {
    nmr_settings_reset(uniqueHandle(), key.index)
  }

  /// The handle, for C calls that only read it during the call.
  func withHandle<Result>(_ body: (OpaquePointer) throws -> Result) rethrows -> Result {
    try body(storage.handle)
  }

  static func == (a: SettingValues, b: SettingValues) -> Bool {
    a.storage === b.storage || nmr_settings_equal(a.storage.handle, b.storage.handle)
  }

  /// The handle, copied first when another value shares it.
  private mutating func uniqueHandle() -> OpaquePointer {
    if !isKnownUniquelyReferenced(&storage) {
      storage = Storage(nmr_settings_copy(storage.handle))
    }
    return storage.handle
  }
}

/// Owns one nmr_settings handle. Unchecked Sendable: values that share a handle only read it (a
/// change copies it first), and a C++ Settings may be read from several threads at once.
private final class Storage: @unchecked Sendable {
  let handle: OpaquePointer

  init(_ handle: OpaquePointer?) {
    guard let handle else { fatalError("out of memory for settings") }
    self.handle = handle
  }

  deinit { nmr_settings_destroy(handle) }
}
