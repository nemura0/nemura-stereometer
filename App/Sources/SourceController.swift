import Foundation
import os

/// Chooses what the meter shows: the system output, a plugin instance from PluginSources, or the
/// `--feed` file.
/// Polls the registry every quarter second while running (memory reads, plus one `proc_name` per
/// instance for its host's name), lists the instances in the popover, and follows the chosen
/// one. Polling also beats the app's heartbeat, which plugins show as "connected", so App Nap is
/// held off while it runs.
/// A chosen instance that goes away stays chosen ("Not sending") until the user picks another:
/// the meter never switches to another source by itself.
@MainActor
final class SourceController {
  private let overlay: OverlayController
  private let model: MeterMenuModel
  private let sources: PluginSources?
  private var timer: Timer?
  private var activity: NSObjectProtocol?
  /// After each poll (the probe waits for its instance here).
  var onPoll: (([PluginInstance]) -> Void)?
  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app", category: "sources")

  init(overlay: OverlayController, model: MeterMenuModel, sources: PluginSources?) {
    self.overlay = overlay
    self.model = model
    self.sources = sources
    if sources == nil { Self.log.error("shared memory is unavailable: no plugin sources") }
    model.onChooseSource = { [weak self] source in self?.choose(source) }
  }

  /// Starts polling for plugin instances (none without shared memory).
  func start() {
    guard timer == nil, sources != nil else { return }
    poll()
    let timer = Timer(timeInterval: PluginSources.pollInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
    timer.tolerance = 0.05
    RunLoop.main.add(timer, forMode: .common)  // also while a menu is open
    self.timer = timer
    activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "Plugin instances watch the app's heartbeat")
  }

  /// Before quitting: the feed and the file stop before the registry closes.
  func stop() {
    timer?.invalidate()
    timer = nil
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    overlay.meter.stopFeed()
    overlay.meter.stopFile()
    sources?.close()
  }

  /// Shows `source`. Choosing the source shown changes nothing, except a file that failed: it
  /// is tried again.
  func choose(_ source: MeterSource) {
    let retry = if case .file = source, case .failed = model.fileState { true } else { false }
    guard retry || !source.isSame(as: model.source) else { return }
    model.source = source
    model.instanceState = .waiting
    if let state = overlay.follow(source, in: sources) { model.fileState = state }
    if case .instance = source { poll() }
  }

  private func poll() {
    guard let sources else { return }
    let instances = sources.poll()
    if instances != model.instances { model.instances = instances }
    if case .instance(let chosen) = model.source {
      if let now = instances.first(where: { $0.id == chosen.id }), now != chosen {
        model.source = .instance(now)
      }
      let state = overlay.meter.updateFeed() ?? .waiting
      if state != model.instanceState { model.instanceState = state }
    }
    onPoll?(instances)
  }
}
