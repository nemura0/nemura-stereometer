import Foundation
import NMRCoreC

/// A plugin instance sending to the app (nmr_source_info).
struct PluginInstance: Identifiable, Equatable, Sendable {
  let id: UInt64
  let name: String
  /// The app it runs in ("Live"); empty when unknown.
  let host: String
  let sampleRate: Double
  let channels: Int

  /// "Bass — Live".
  var title: String { host.isEmpty ? name : "\(name) — \(host)" }

  init(id: UInt64, name: String, host: String, sampleRate: Double, channels: Int) {
    self.id = id
    self.name = name
    self.host = host
    self.sampleRate = sampleRate
    self.channels = channels
  }

  init(_ info: nmr_source_info) {
    self.init(
      id: info.instance_id, name: Self.text(info.name), host: Self.text(info.host),
      sampleRate: info.sample_rate,
      channels: Int(info.channels))
  }
}

extension PluginInstance {
  /// A fixed-size C string field, up to its NUL.
  fileprivate static func text<T>(_ field: T) -> String {
    withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  }
}

/// What the meter shows.
enum MeterSource: Equatable, Sendable {
  case systemOutput
  /// The instance as last listed (kept while it is away).
  case instance(PluginInstance)
  /// `--feed`: a WAV file played in a loop.
  case file(URL)

  /// Whether both name the same source, whatever an instance's rate or name is now.
  func isSame(as other: MeterSource) -> Bool {
    switch (self, other) {
    case (.systemOutput, .systemOutput): true
    case (.instance(let a), .instance(let b)): a.id == b.id
    case (.file(let a), .file(let b)): a == b
    default: false
    }
  }
}

/// How the `--feed` file plays.
enum FileState: Equatable, Sendable {
  enum Problem: Equatable, Sendable {
    case unreadable, notWAV, unsupported, empty, tooLong, failed

    init(_ error: nmr_feed_error) {
      switch error {
      case NMR_FEED_NOT_WAV: self = .notWAV
      case NMR_FEED_UNSUPPORTED: self = .unsupported
      case NMR_FEED_EMPTY: self = .empty
      case NMR_FEED_TOO_LONG: self = .tooLong
      case NMR_FEED_FAILED: self = .failed
      default: self = .unreadable
      }
    }

    var description: String {
      switch self {
      case .unreadable: "The file could not be read"
      case .notWAV: "Not a WAV file"
      case .unsupported: "A WAV format it cannot play"
      case .empty: "The file holds no audio"
      case .tooLong: "The file is too long to play"
      case .failed: "The file could not be played"
      }
    }
  }

  case playing(sampleRate: Double)
  case failed(Problem)
}

/// How the chosen instance is doing (nmr_instance_state).
enum InstanceState: Equatable, Sendable {
  case waiting, sending, quiet

  init(_ state: nmr_instance_state) {
    switch state {
    case NMR_INSTANCE_SENDING: self = .sending
    case NMR_INSTANCE_QUIET: self = .quiet
    default: self = .waiting
    }
  }
}

/// The shared-memory registry plugin instances send through: lists the live instances and keeps
/// the app's heartbeat, which plugins show as "connected". Poll it every quarter second.
@MainActor
final class PluginSources {
  static let pollInterval = 0.25
  /// The most instances listed at once (the registry's slot count).
  static let capacity = 16

  private(set) var handle: OpaquePointer?

  /// Nil when shared memory is unavailable (or holds another protocol version).
  init?(prefix: String? = nil) {
    guard let opened = nmr_sources_open(prefix) else { return nil }
    handle = opened
  }

  /// Beats, frees the slots of processes that died, and lists the instances sending now.
  func poll() -> [PluginInstance] {
    guard let handle else { return [] }
    var infos = [nmr_source_info](repeating: nmr_source_info(), count: Self.capacity)
    let count = Int(nmr_sources_poll(handle, &infos, UInt32(Self.capacity)))
    return infos.prefix(count).map(PluginInstance.init)
  }

  /// Ends the heartbeat. Stop every feed made from this first (MeterController.stopFeed).
  func close() {
    nmr_sources_close(handle)
    handle = nil
  }
}
