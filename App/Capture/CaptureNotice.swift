/// What the meter tells the user about the capture, if anything: a failure always shows (no
/// silent fallback), and so does silence while another app plays, the sign of a denied
/// audio-capture permission (a denied grant delivers zeros, not errors).
enum CaptureNotice: Equatable, Sendable {
  case failed(step: String, status: Int32)
  case silenceWhilePlaying

  /// Nil while starting (the permission prompt may be open), while capturing silence with nothing
  /// else playing, and once sound arrives.
  init?(_ state: CaptureState) {
    switch state.phase {
    case .starting: return nil
    case .failed(let step, let status): self = .failed(step: step, status: status)
    case .capturing:
      guard state.signal == .silenceWhilePlaying else { return nil }
      self = .silenceWhilePlaying
    }
  }

  var message: String {
    switch self {
    case .failed(let step, let status):
      let place = step.isEmpty ? "" : "\(step), "
      return "Can't capture the system output (\(place)error \(status))."
    case .silenceWhilePlaying:
      return "Only silence arrives while audio plays. The audio permission may be off."
    }
  }

  var actionTitle: String {
    switch self {
    case .failed: "Try Again"
    case .silenceWhilePlaying: "How to Fix…"
    }
  }
}
