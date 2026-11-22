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

  enum SecondsError: Error, Equatable {
    case invalid(String)
  }

  /// What a probe may run for.
  static let probeSeconds: ClosedRange<Double> = 1...600

  /// The seconds after `option`: `fallback` when none are given, an error when the value is not a
  /// finite number in probeSeconds (never a silent fallback for a typo).
  func seconds(after option: String, default fallback: Double) -> Result<Double, SecondsError> {
    guard let text = value(after: option) else { return .success(fallback) }
    guard let seconds = Double(text), seconds.isFinite, Self.probeSeconds.contains(seconds) else {
      return .failure(.invalid(text))
    }
    return .success(seconds)
  }
}
