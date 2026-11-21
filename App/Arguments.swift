/// Minimal command-line parsing for the app's debug options.
struct Arguments: Sendable {
  private let values: [String]

  init(_ commandLine: [String]) {
    values = Array(commandLine.dropFirst())
  }

  func contains(_ option: String) -> Bool {
    values.contains(option)
  }

  /// The value that follows `option`, unless it is missing or is another option.
  func value(after option: String) -> String? {
    guard let index = values.firstIndex(of: option), index + 1 < values.count else { return nil }
    let value = values[index + 1]
    return value.hasPrefix("--") ? nil : value
  }

  func double(after option: String) -> Double? {
    value(after: option).flatMap(Double.init)
  }
}
