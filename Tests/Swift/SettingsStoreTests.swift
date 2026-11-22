import Foundation
import Testing

@testable import App

/// A defaults domain of its own, removed afterwards.
private final class TestDefaults {
  let name = "nmr-test-\(UUID().uuidString)"
  let defaults: UserDefaults

  init() throws {
    defaults = try #require(UserDefaults(suiteName: name))
  }

  deinit { UserDefaults().removePersistentDomain(forName: name) }
}

@MainActor
@Suite("Settings store")
struct SettingsStoreTests {
  @Test("The first run starts from the NEMURA preset, click-through off")
  func firstRun() throws {
    let domain = try TestDefaults()
    let store = SettingsStore(defaults: domain.defaults)
    #expect(store.values.choice(.mode) == "original")
    #expect(!store.values.flag(.clickThrough))
    #expect(domain.defaults.string(forKey: SettingsStore.key) == nil)  // nothing changed yet
  }

  @Test("Changes are kept for the next run, except click-through")
  func keptBetweenRuns() throws {
    let domain = try TestDefaults()
    let store = SettingsStore(defaults: domain.defaults)
    store.update { values in
      values.set(.gainDb, to: 6)
      values.set(.mode, choice: "lissajous")
      values.set(.clickThrough, to: 1)
    }
    #expect(store.values.flag(.clickThrough))

    let next = SettingsStore(defaults: domain.defaults)
    #expect(next.values.number(.gainDb) == 6)
    #expect(next.values.choice(.mode) == "lissajous")
    #expect(!next.values.flag(.clickThrough))  // a window that ignores the mouse is never first
  }

  @Test("Unreadable saved settings start from the first-run settings")
  func unreadable() throws {
    let domain = try TestDefaults()
    domain.defaults.set("{not json", forKey: SettingsStore.key)
    #expect(SettingsStore(defaults: domain.defaults).values.choice(.mode) == "original")
    domain.defaults.set(42, forKey: SettingsStore.key)
    #expect(SettingsStore(defaults: domain.defaults).values.choice(.mode) == "original")
  }

  @Test("Without defaults (the probe) nothing is written")
  func probeWritesNothing() throws {
    let store = SettingsStore(defaults: nil)
    store.update { $0.set(.gainDb, to: 3) }
    #expect(store.values.number(.gainDb) == 3)
  }

  @Test("Observers hear each change once, and nothing for no change")
  func observers() throws {
    let domain = try TestDefaults()
    let store = SettingsStore(defaults: domain.defaults)
    var heard: [Double] = []
    store.observe { heard.append($0.number(.gainDb)) }
    store.update { $0.set(.gainDb, to: 4) }
    store.update { $0.set(.gainDb, to: 4) }
    store.replace(store.values)
    var other = store.values
    other.set(.gainDb, to: -2)
    store.replace(other)
    #expect(heard == [4, -2])
  }

  @Test("A preset changes the look and keeps the window behavior")
  func presets() throws {
    let domain = try TestDefaults()
    let store = SettingsStore(defaults: domain.defaults)
    let mix = try #require(Presets.factory.first { $0.name == "Mix" })
    store.update { $0.set(.dockIcon, to: 1) }
    store.apply(mix)
    #expect(store.values.choice(.mode) == mix.settings.choice(.mode))
    #expect(store.values.flag(.dockIcon))
    #expect(store.matches(mix))
    #expect(store.matchingPreset(in: Presets.factory)?.name == "Mix")

    store.update { $0.set(.allSpaces, to: 0) }  // window behavior: not part of the look
    #expect(store.matches(mix))
    store.update { $0.set(.gainDb, to: store.values.number(.gainDb) + 1) }
    #expect(!store.matches(mix))
    #expect(store.matchingPreset(in: Presets.factory) == nil)
  }
}
