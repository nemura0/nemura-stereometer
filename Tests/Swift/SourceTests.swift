import Darwin
import Foundation
import NMRCoreC
import Testing

@testable import App

/// A registry of the test's own, removed afterwards.
private final class TestRegistry {
  let prefix = "/nmr.t\(getpid()).s\(UInt32.random(in: 0..<100_000))"

  deinit {
    shm_unlink(prefix + ".reg")
    for slot in 0..<16 { shm_unlink(prefix + ".r\(slot)") }
  }
}

@MainActor
@Suite("Meter sources")
struct SourceTests {
  @Test("An empty registry lists nothing; a feed for an absent instance waits and shows nothing")
  func emptyRegistry() throws {
    let registry = TestRegistry()
    let sources = try #require(PluginSources(prefix: registry.prefix))
    #expect(sources.poll().isEmpty)
    var transparent: [Float] = [0, 0, 0, 0]
    let raw = try #require(nmr_render_view_create(64, 64, &transparent))
    let view = Unmanaged<NSObject>.fromOpaque(raw)
    defer { view.release() }
    let feed = try #require(nmr_instance_feed_create(raw, sources.handle, 42))
    #expect(nmr_instance_feed_update(feed) == NMR_INSTANCE_WAITING)
    nmr_instance_feed_destroy(feed)
    sources.close()
    sources.close()  // twice is fine
  }

  @Test("The C calls refuse missing arguments")
  func nullArguments() {
    #expect(nmr_sources_poll(nil, nil, 0) == 0)
    #expect(nmr_instance_feed_create(nil, nil, 1) == nil)
    #expect(nmr_instance_feed_update(nil) == NMR_INSTANCE_WAITING)
    nmr_instance_feed_destroy(nil)
    nmr_sources_close(nil)
  }

  @Test("An instance reads as its name and the app it runs in")
  func instanceTitle() {
    let bass = PluginInstance(id: 1, name: "Bass", host: "Live", sampleRate: 48000, channels: 2)
    #expect(bass.title == "Bass — Live")
    let bare = PluginInstance(id: 2, name: "Bass", host: "", sampleRate: 48000, channels: 2)
    #expect(bare.title == "Bass")
  }

  @Test("The source line follows the chosen instance")
  func instanceStatus() {
    let menu = MeterMenuModel(store: SettingsStore(defaults: nil), presetFolder: nil)
    #expect(menu.sourceTitle == "System Output")
    var chosen: MeterSource?
    menu.onChooseSource = { chosen = $0 }
    let bass = PluginInstance(id: 7, name: "Bass", host: "Live", sampleRate: 44100, channels: 1)
    menu.instances = [bass]
    menu.choose(.instance(bass))
    #expect(chosen == .instance(bass))

    menu.source = .instance(bass)
    menu.instanceState = .sending
    #expect(menu.sourceTitle == "Bass — Live")
    #expect(menu.sourceStatus == "44.1 kHz, mono")
    menu.instanceState = .quiet
    #expect(menu.sourceStatus == "Paused in the host")
    menu.instanceState = .waiting
    #expect(menu.sourceStatus == "Not sending")
  }

  @Test("A WAV file plays into the meter; other files say why they do not")
  func fileFeed() throws {
    let folder = try TemporaryFolder()
    let wav = folder.url.appending(path: "mix.wav")
    try TestWAV.write(to: wav, frames: 4800, rate: 44100)
    var transparent: [Float] = [0, 0, 0, 0]
    let raw = try #require(nmr_render_view_create(64, 64, &transparent))
    let view = Unmanaged<NSObject>.fromOpaque(raw)
    defer { view.release() }

    var error = NMR_FEED_UNREADABLE
    var rate = 0.0
    let feed = try #require(nmr_file_feed_create(raw, wav.path, &error, &rate))
    #expect(error == NMR_FEED_OK)
    #expect(rate == 44100)
    nmr_file_feed_destroy(feed)

    let text = folder.url.appending(path: "notes.wav")
    try "hello".write(to: text, atomically: true, encoding: .utf8)
    #expect(nmr_file_feed_create(raw, text.path, &error, nil) == nil)
    #expect(error == NMR_FEED_NOT_WAV)
    #expect(nmr_file_feed_create(raw, folder.url.appending(path: "none.wav").path, &error, nil)
      == nil)
    #expect(error == NMR_FEED_UNREADABLE)
    #expect(nmr_file_feed_create(nil, wav.path, &error, nil) == nil)
    nmr_file_feed_destroy(nil)
  }

  @Test("A file source reads as its name and how it plays")
  func fileStatus() {
    let menu = MeterMenuModel(store: SettingsStore(defaults: nil), presetFolder: nil)
    let url = URL(filePath: "/tmp/Mix.wav")
    menu.source = .file(url)
    menu.fileState = .playing(sampleRate: 48000)
    #expect(menu.sourceTitle == "File: Mix.wav")
    #expect(menu.sourceStatus == "48 kHz, looping")
    menu.fileState = .failed(.notWAV)
    #expect(menu.sourceStatus == "Not a WAV file")
    #expect(MeterSource.file(url).isSame(as: .file(url)))
    #expect(!MeterSource.file(url).isSame(as: .systemOutput))
  }
}
