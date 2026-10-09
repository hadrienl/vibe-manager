import Foundation
import Testing
import VibeApplication

@testable import VibeConversationUI

/// A voice that says nothing: it records what it was asked to read, and reads until cancelled.
private final class FakeSynthesizer: SpeechSynthesizing, @unchecked Sendable {
  private let lock = NSLock()
  private var installed: Bool
  private var _spoken: [(text: String, voice: SpeechVoice, language: SpeechLanguage)] = []
  private var _stopped = 0
  /// Whether a reading lasts until it is cancelled, rather than ending at once.
  let readsUntilCancelled: Bool

  init(installed: Bool, readsUntilCancelled: Bool = true) {
    self.installed = installed
    self.readsUntilCancelled = readsUntilCancelled
  }

  var spoken: [(text: String, voice: SpeechVoice, language: SpeechLanguage)] {
    lock.withLock { _spoken }
  }
  var stopped: Int { lock.withLock { _stopped } }

  func installedSize() -> Int64? { lock.withLock { installed ? 900 : nil } }
  var downloadSize: Int64 { 1_000 }

  func download(progress: @escaping @Sendable (Double) -> Void) async throws {
    progress(1)
    lock.withLock { installed = true }
  }

  func speak(_ text: String, voice: SpeechVoice, language: SpeechLanguage) async throws {
    lock.withLock { _spoken.append((text, voice, language)) }
    guard readsUntilCancelled else { return }
    while !Task.isCancelled { await Task.yield() }
    lock.withLock { _stopped += 1 }
    throw CancellationError()
  }

  func prepare() async throws {
    lock.withLock { _prepared += 1 }
  }
  private var _prepared = 0
  var prepared: Int { lock.withLock { _prepared } }

  func remove() async throws { lock.withLock { installed = false } }
}

@MainActor
private func until(_ condition: () -> Bool) async {
  for _ in 0..<10_000 where !condition() { await Task.yield() }
}

@Suite("The answers read aloud (#357)")
@MainActor
struct ReadAloudControllerTests {
  @Test("An answer is read as prose, in the voice and language chosen")
  func reads() async {
    let synthesizer = FakeSynthesizer(installed: true, readsUntilCancelled: false)
    let readAloud = ReadAloudController(
      synthesizer: synthesizer,
      store: InMemorySpeechSettingsStore(
        settings: SpeechSettings(voice: .ryan, language: .french)))

    readAloud.read("**Fait.** Voir `Package.swift`.\n\n```\ncode\n```", id: "a")
    #expect(readAloud.isReading("a"))
    await until { readAloud.phase == .idle }
    #expect(synthesizer.spoken.map(\.text) == ["Fait. Voir Package.swift."])
    #expect(synthesizer.spoken.map(\.voice) == [.ryan])
    #expect(synthesizer.spoken.map(\.language) == [.french])
  }

  @Test("Reading another answer stops the first; Stop stops it at once")
  func oneVoiceAtATime() async {
    let synthesizer = FakeSynthesizer(installed: true)
    let readAloud = ReadAloudController(
      synthesizer: synthesizer, store: InMemorySpeechSettingsStore())

    readAloud.read("First answer.", id: "a")
    await until { synthesizer.spoken.count == 1 }
    readAloud.read("Second answer.", id: "b")
    await until { synthesizer.stopped == 1 && synthesizer.spoken.count == 2 }
    #expect(readAloud.isReading("b"))
    #expect(!readAloud.isReading("a"))

    readAloud.stop()
    #expect(readAloud.phase == .idle)
    await until { synthesizer.stopped == 2 }
    #expect(synthesizer.stopped == 2)
    #expect(readAloud.phase == .idle)
  }

  @Test("Without the model, Settings opens and nothing is read")
  func withoutModel() {
    let synthesizer = FakeSynthesizer(installed: false)
    let readAloud = ReadAloudController(
      synthesizer: synthesizer, store: InMemorySpeechSettingsStore())
    var shown = 0
    readAloud.showSettings = { shown += 1 }

    readAloud.read("An answer.", id: "a")
    #expect(shown == 1)
    #expect(readAloud.phase == .idle)
    #expect(synthesizer.spoken.isEmpty)
  }

  @Test("Downloaded from Settings, the model is said ready and reads nothing by itself")
  func download() async {
    let synthesizer = FakeSynthesizer(installed: false)
    let readAloud = ReadAloudController(
      synthesizer: synthesizer, store: InMemorySpeechSettingsStore())
    var ready = 0
    readAloud.modelDidBecomeReady = { ready += 1 }

    readAloud.downloadModel()
    await until { readAloud.isModelInstalled && readAloud.phase == .idle }
    #expect(ready == 1)
    #expect(synthesizer.spoken.isEmpty)

    await readAloud.removeModel()
    #expect(!readAloud.isModelInstalled)
  }

  @Test("The voice is loaded once in the background, when a conversation comes on screen")
  func warmUp() async {
    let synthesizer = FakeSynthesizer(installed: true, readsUntilCancelled: false)
    let readAloud = ReadAloudController(
      synthesizer: synthesizer, store: InMemorySpeechSettingsStore())

    readAloud.warmUp()
    readAloud.warmUp()
    await until { synthesizer.prepared == 1 }
    for _ in 0..<50 { await Task.yield() }
    #expect(synthesizer.prepared == 1)
    #expect(readAloud.phase == .idle)
  }

  @Test("An answer of code alone reads nothing")
  func nothingToRead() {
    let synthesizer = FakeSynthesizer(installed: true)
    let readAloud = ReadAloudController(
      synthesizer: synthesizer, store: InMemorySpeechSettingsStore())

    readAloud.read("```\nls\n```", id: "a")
    #expect(readAloud.phase == .idle)
  }
}
