import Foundation

/// What the app remembers about the audio-capture permission between runs.
///
/// `soundSeen` means a run once got sound: the grant (bound to the code signature) works, so
/// later runs neither watch the signal nor suspect it. If the user turns the permission off
/// afterwards, the quick menu's "Audio Permission…" still explains how to turn it on.
struct CaptureMemory {
  static let introShownKey = "permissionIntroShown"
  static let soundSeenKey = "captureSoundSeen"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The first-run window explained the permission.
  var introShown: Bool {
    get { defaults.bool(forKey: Self.introShownKey) }
    nonmutating set { defaults.set(newValue, forKey: Self.introShownKey) }
  }

  var soundSeen: Bool {
    get { defaults.bool(forKey: Self.soundSeenKey) }
    nonmutating set { defaults.set(newValue, forKey: Self.soundSeenKey) }
  }

  /// Keeps what `state` proves: sound means the permission is granted.
  func remember(_ state: CaptureState) {
    if state.signal == .sound && !soundSeen { soundSeen = true }
  }
}
