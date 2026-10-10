import Foundation
import Testing
import VibeApplication

@testable import VibeConversationUI

/// A voice that says nothing: it records what it was asked to read, and reads until cancelled.
final class FakeSynthesizer: SpeechSynthesizing, @unchecked Sendable {
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

  func prepare(voice: SpeechVoice, language: SpeechLanguage) async throws {
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

@Suite("The audio mode (#357)")
@MainActor
struct AudioModeTests {
  private final class Conversation {}

  private func controller(_ synthesizer: FakeSynthesizer, on: Bool = true) -> ReadAloudController {
    ReadAloudController(
      synthesizer: synthesizer,
      store: InMemorySpeechSettingsStore(settings: SpeechSettings(readsAnswers: on)))
  }

  @Test("The answers already there are never read; those that arrive are, one after the other")
  func readsWhatArrives() async {
    let synthesizer = FakeSynthesizer(installed: true, readsUntilCancelled: false)
    let readAloud = controller(synthesizer)
    let conversation = ObjectIdentifier(Conversation())

    readAloud.follow([("old", "Old answer.")], in: conversation, isOnScreen: true)
    #expect(readAloud.phase == .idle)

    readAloud.follow(
      [("old", "Old answer."), ("a", "First."), ("b", "Second.")], in: conversation,
      isOnScreen: true)
    await until { synthesizer.spoken.count == 2 && readAloud.phase == .idle }
    #expect(synthesizer.spoken.map(\.text) == ["First.", "Second."])
  }

  @Test("Off, or out of sight, nothing is read — and what arrived then is not read later")
  func onlyOnScreenAndOn() async {
    let synthesizer = FakeSynthesizer(installed: true, readsUntilCancelled: false)
    let readAloud = controller(synthesizer, on: false)
    let conversation = ObjectIdentifier(Conversation())

    readAloud.follow([], in: conversation, isOnScreen: true)
    readAloud.follow([("a", "Off.")], in: conversation, isOnScreen: true)
    readAloud.settings.readsAnswers = true
    readAloud.follow([("a", "Off."), ("b", "Hidden.")], in: conversation, isOnScreen: false)
    readAloud.follow(
      [("a", "Off."), ("b", "Hidden."), ("c", "Shown.")], in: conversation, isOnScreen: true)
    await until { synthesizer.spoken.count == 1 && readAloud.phase == .idle }
    #expect(synthesizer.spoken.map(\.text) == ["Shown."])
  }

  @Test("A discussion ended on a sentence reads the answer to it, then nothing more")
  func readsTheLastAnswer() async {
    let synthesizer = FakeSynthesizer(installed: true, readsUntilCancelled: false)
    let readAloud = controller(synthesizer, on: false)
    let conversation = ObjectIdentifier(Conversation())

    readAloud.follow([], in: conversation, isOnScreen: true)
    readAloud.readsConversation = conversation
    readAloud.readsNextAnswerOnly = true
    readAloud.follow([("a", "The answer.")], in: conversation, isOnScreen: true)
    await until { synthesizer.spoken.count == 1 && readAloud.phase == .idle }
    readAloud.follow([("a", "The answer."), ("b", "Another.")], in: conversation, isOnScreen: true)
    for _ in 0..<100 { await Task.yield() }
    #expect(synthesizer.spoken.map(\.text) == ["The answer."])
    #expect(readAloud.readsConversation == nil)
  }

  @Test("Stop, an answer read by hand, or the mode turned off clears what was to be read")
  func stopClearsTheQueue() async {
    let synthesizer = FakeSynthesizer(installed: true)
    let readAloud = controller(synthesizer)
    let conversation = ObjectIdentifier(Conversation())

    readAloud.follow([], in: conversation, isOnScreen: true)
    readAloud.follow([("a", "One."), ("b", "Two.")], in: conversation, isOnScreen: true)
    await until { synthesizer.spoken.count == 1 }
    readAloud.stop()
    for _ in 0..<200 { await Task.yield() }
    #expect(synthesizer.spoken.map(\.text) == ["One."])

    readAloud.follow(
      [("a", "One."), ("b", "Two."), ("c", "Three."), ("d", "Four.")], in: conversation,
      isOnScreen: true)
    await until { synthesizer.spoken.count == 2 }
    readAloud.settings.readsAnswers = false
    for _ in 0..<200 { await Task.yield() }
    #expect(synthesizer.spoken.map(\.text) == ["One.", "Three."])
    #expect(readAloud.phase == .idle)
  }
}
