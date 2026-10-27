import Foundation
import Testing
import VibeApplication

@testable import VibeConversationUI

/// A voice that says nothing: it records what it was asked to read, and reads until cancelled.
final class FakeSynthesizer: SpeechSynthesizing, @unchecked Sendable {
  private let lock = NSLock()
  private var installed: Bool
  private var spokenLog: [(text: String, voice: SpeechVoice, language: SpeechLanguage)] = []
  private var stopCount = 0
  /// Whether a reading lasts until it is cancelled, rather than ending at once.
  let readsUntilCancelled: Bool

  init(installed: Bool, readsUntilCancelled: Bool = true) {
    self.installed = installed
    self.readsUntilCancelled = readsUntilCancelled
  }

  var spoken: [(text: String, voice: SpeechVoice, language: SpeechLanguage)] {
    lock.withLock { spokenLog }
  }
  var stopped: Int { lock.withLock { stopCount } }

  func installedSize() -> Int64? { lock.withLock { installed ? 900 : nil } }
  var downloadSize: Int64 { 1_000 }

  /// Whether a download lasts until it is cancelled, or until `finishDownload` when it ignores
  /// the cancellation.
  var holdsDownload = false
  var ignoresCancellation = false
  private var downloadFinished = false
  private var removeCount = 0
  var removed: Int { lock.withLock { removeCount } }

  func finishDownload() { lock.withLock { downloadFinished = true } }

  func download(progress: @escaping @Sendable (Double) -> Void) async throws {
    progress(0.5)
    while holdsDownload, !lock.withLock({ downloadFinished }) {
      if Task.isCancelled, !ignoresCancellation { throw CancellationError() }
      await Task.yield()
    }
    progress(1)
    lock.withLock { installed = true }
  }

  /// Whether a reading fails, as a model that cannot load would.
  var speakingFails = false

  func speak(_ text: String, voice: SpeechVoice, language: SpeechLanguage) async throws {
    if speakingFails { throw CancellationError() }
    lock.withLock { spokenLog.append((text, voice, language)) }
    guard readsUntilCancelled else { return }
    while !Task.isCancelled { await Task.yield() }
    lock.withLock { stopCount += 1 }
    throw CancellationError()
  }

  func prepare() async throws {
    lock.withLock { prepareCount += 1 }
  }

  func prepare(voice _: SpeechVoice, language _: SpeechLanguage) async throws {
    lock.withLock { prepareCount += 1 }
  }
  private var prepareCount = 0
  var prepared: Int { lock.withLock { prepareCount } }

  func remove() async throws {
    lock.withLock {
      installed = false
      removeCount += 1
    }
  }
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

  @Test("A download cancelled stops, and nothing of it is kept")
  func cancelDownload() async {
    let synthesizer = FakeSynthesizer(installed: false)
    synthesizer.holdsDownload = true
    let readAloud = ReadAloudController(
      synthesizer: synthesizer, store: InMemorySpeechSettingsStore())
    var ready = 0
    readAloud.modelDidBecomeReady = { ready += 1 }

    readAloud.downloadModel()
    await until { readAloud.phase == .downloading(fraction: 0.5) }
    readAloud.cancelDownload()
    #expect(readAloud.phase == .idle)
    await until { synthesizer.removed == 1 }
    #expect(synthesizer.removed == 1)
    #expect(!readAloud.isModelInstalled)
    #expect(readAloud.problem == nil)
    #expect(ready == 0)
  }

  @Test("A download cancelled that ends all the same is removed, and said ready to no one")
  func cancelledDownloadEnds() async {
    let synthesizer = FakeSynthesizer(installed: false)
    synthesizer.holdsDownload = true
    synthesizer.ignoresCancellation = true
    let readAloud = ReadAloudController(
      synthesizer: synthesizer, store: InMemorySpeechSettingsStore())
    var ready = 0
    readAloud.modelDidBecomeReady = { ready += 1 }

    readAloud.downloadModel()
    await until { readAloud.phase == .downloading(fraction: 0.5) }
    readAloud.cancelDownload()
    synthesizer.finishDownload()
    await until { synthesizer.removed == 2 }
    #expect(synthesizer.removed == 2)
    #expect(!readAloud.isModelInstalled)
    #expect(readAloud.phase == .idle)
    #expect(ready == 0)
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

  @Test("The model deleted and downloaded again is loaded again in the background")
  func warmsUpAfterDeletion() async {
    let synthesizer = FakeSynthesizer(installed: true)
    let readAloud = ReadAloudController(
      synthesizer: synthesizer, store: InMemorySpeechSettingsStore())

    readAloud.warmUp()
    await until { synthesizer.prepared == 1 }
    await readAloud.removeModel()
    #expect(!readAloud.isModelInstalled)
    readAloud.downloadModel()
    await until { readAloud.isModelInstalled && readAloud.phase == .idle }
    readAloud.warmUp()
    await until { synthesizer.prepared == 2 }
    #expect(synthesizer.prepared == 2)
  }

  @Test("An answer of code alone reads nothing")
  func nothingToRead() {
    let synthesizer = FakeSynthesizer(installed: true)
    let readAloud = ReadAloudController(
      synthesizer: synthesizer, store: InMemorySpeechSettingsStore())

    readAloud.read("```\nls\n```", id: "a")
    #expect(readAloud.phase == .idle)
  }

  @Test("An answer of code alone asked for while another is read stops that one")
  func nothingToReadStopsTheReading() async {
    let synthesizer = FakeSynthesizer(installed: true)
    let readAloud = ReadAloudController(
      synthesizer: synthesizer, store: InMemorySpeechSettingsStore())

    readAloud.read("Les tests passent.", id: "a")
    await until { readAloud.phase == .reading(id: "a") }
    readAloud.read("```\nls\n```", id: "b")
    #expect(readAloud.phase == .idle)
    #expect(!readAloud.isReading)
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

    readAloud.follow([("old", "Old answer.", nil)], in: conversation, isOnScreen: true)
    #expect(readAloud.phase == .idle)

    readAloud.follow(
      [("old", "Old answer.", nil), ("a", "First.", nil), ("b", "Second.", nil)], in: conversation,
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
    readAloud.follow([("a", "Off.", nil)], in: conversation, isOnScreen: true)
    readAloud.settings.readsAnswers = true
    readAloud.follow([("a", "Off.", nil), ("b", "Hidden.", nil)], in: conversation, isOnScreen: false)
    readAloud.follow(
      [("a", "Off.", nil), ("b", "Hidden.", nil), ("c", "Shown.", nil)], in: conversation, isOnScreen: true)
    await until { synthesizer.spoken.count == 1 && readAloud.phase == .idle }
    #expect(synthesizer.spoken.map(\.text) == ["Shown."])
  }

  @Test("A discussion ended on a sentence reads the agent's whole turn, then nothing more")
  func readsTheLastAnswer() async {
    let synthesizer = FakeSynthesizer(installed: true, readsUntilCancelled: false)
    let readAloud = controller(synthesizer, on: false)
    let conversation = ObjectIdentifier(Conversation())

    readAloud.follow([], in: conversation, isOnScreen: true)
    readAloud.readsConversation = conversation
    readAloud.readsNextAnswerOnly = true
    // The turn ends before anything was answered: the discussion waits for its answer.
    readAloud.turnEnded(in: conversation)
    #expect(readAloud.readsConversation == conversation)
    readAloud.follow([("a", "Let me look.", nil)], in: conversation, isOnScreen: true)
    // Its tools, then its answer: the same turn.
    readAloud.follow(
      [("a", "Let me look.", nil), ("b", "Fixed.", nil)], in: conversation, isOnScreen: true)
    await until { synthesizer.spoken.count == 2 && readAloud.phase == .idle }
    readAloud.turnEnded(in: conversation)
    #expect(readAloud.readsConversation == nil)
    readAloud.follow(
      [("a", "Let me look.", nil), ("b", "Fixed.", nil), ("c", "Another.", nil)],
      in: conversation, isOnScreen: true)
    for _ in 0..<100 { await Task.yield() }
    #expect(synthesizer.spoken.map(\.text) == ["Let me look.", "Fixed."])
  }

  @Test("While a dictation records, the audio mode reads nothing; it reads what came once closed")
  func suspended() async {
    let synthesizer = FakeSynthesizer(installed: true, readsUntilCancelled: false)
    let readAloud = controller(synthesizer)
    let conversation = ObjectIdentifier(Conversation())

    readAloud.follow([], in: conversation, isOnScreen: true)
    readAloud.isSuspended = true
    readAloud.follow([("a", "Meanwhile.", nil)], in: conversation, isOnScreen: true)
    for _ in 0..<100 { await Task.yield() }
    #expect(synthesizer.spoken.isEmpty)
    #expect(readAloud.phase == .idle)

    readAloud.isSuspended = false
    await until { synthesizer.spoken.count == 1 && readAloud.phase == .idle }
    #expect(synthesizer.spoken.map(\.text) == ["Meanwhile."])
  }

  @Test("A reading that fails is said, until put away")
  func readingFails() async {
    let synthesizer = FakeSynthesizer(installed: true, readsUntilCancelled: false)
    synthesizer.speakingFails = true
    let readAloud = controller(synthesizer)

    readAloud.read("An answer.", id: "a")
    await until { readAloud.problem != nil }
    #expect(readAloud.problem == .readingFailed)
    #expect(readAloud.phase == .idle)
    readAloud.dismissProblem()
    #expect(readAloud.problem == nil)
  }

  @Test("Stop, an answer read by hand, or the mode turned off clears what was to be read")
  func stopClearsTheQueue() async {
    let synthesizer = FakeSynthesizer(installed: true)
    let readAloud = controller(synthesizer)
    let conversation = ObjectIdentifier(Conversation())

    readAloud.follow([], in: conversation, isOnScreen: true)
    readAloud.follow([("a", "One.", nil), ("b", "Two.", nil)], in: conversation, isOnScreen: true)
    await until { synthesizer.spoken.count == 1 }
    readAloud.stop()
    for _ in 0..<200 { await Task.yield() }
    #expect(synthesizer.spoken.map(\.text) == ["One."])

    readAloud.follow(
      [("a", "One.", nil), ("b", "Two.", nil), ("c", "Three.", nil), ("d", "Four.", nil)], in: conversation,
      isOnScreen: true)
    await until { synthesizer.spoken.count == 2 }
    readAloud.settings.readsAnswers = false
    for _ in 0..<200 { await Task.yield() }
    #expect(synthesizer.spoken.map(\.text) == ["One.", "Three."])
    #expect(readAloud.phase == .idle)
  }

  @Test("Back on a conversation, what came while it was out of sight is not read; what comes is")
  func notTheBacklog() async {
    let synthesizer = FakeSynthesizer(installed: true, readsUntilCancelled: false)
    let readAloud = controller(synthesizer)
    let conversation = ObjectIdentifier(Conversation())
    let start = Date(timeIntervalSince1970: 1_000)

    readAloud.follow([], in: conversation, isOnScreen: true, now: start)
    readAloud.follow([], in: conversation, isOnScreen: false, now: start + 1)
    // Shown again at 3600: the answers written meanwhile are laid out after it.
    readAloud.follow([], in: conversation, isOnScreen: true, now: start + 3_600)
    readAloud.follow(
      [("a", "While away.", start + 60), ("b", "Away too.", start + 1_800)], in: conversation,
      isOnScreen: true, now: start + 3_601)
    readAloud.follow(
      [("a", "While away.", start + 60), ("b", "Away too.", start + 1_800),
       ("c", "Now.", start + 3_610)],
      in: conversation, isOnScreen: true, now: start + 3_611)
    await until { synthesizer.spoken.count == 1 && readAloud.phase == .idle }
    #expect(synthesizer.spoken.map(\.text) == ["Now."])
  }

  @Test("A conversation out of sight stops what the audio mode read of it, and what it was to read")
  func leavingStops() async {
    let synthesizer = FakeSynthesizer(installed: true)
    let readAloud = controller(synthesizer)
    let conversation = ObjectIdentifier(Conversation())

    readAloud.follow([], in: conversation, isOnScreen: true)
    readAloud.follow([("a", "One.", nil), ("b", "Two.", nil)], in: conversation, isOnScreen: true)
    await until { readAloud.phase == .reading(id: "a") }
    readAloud.follow([("a", "One.", nil), ("b", "Two.", nil)], in: conversation, isOnScreen: false)
    #expect(readAloud.phase == .idle)
    for _ in 0..<200 { await Task.yield() }
    #expect(synthesizer.spoken.map(\.text) == ["One."])
  }

  @Test("The audio mode turned off leaves an answer read by hand to its end")
  func offKeepsTheReadingByHand() async {
    let synthesizer = FakeSynthesizer(installed: true)
    let readAloud = controller(synthesizer)

    readAloud.read("Read by hand.", id: "a")
    await until { readAloud.phase == .reading(id: "a") }
    readAloud.settings.readsAnswers = false
    #expect(readAloud.phase == .reading(id: "a"))
    readAloud.stop()
  }
}
