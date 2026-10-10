import Foundation
import Testing
import VibeApplication

@testable import VibeConversationUI

/// A microphone that hears what the test says, and asks nobody.
@MainActor
private final class FakeRecorder: AudioRecording {
  var access = MicrophoneAccess.granted
  /// What the user answers when the system asks.
  var grants = true
  var failsToStart = false
  var heard: [Float] = []
  private(set) var isRecording = false

  func requestAccess() async -> Bool {
    access = grants ? .granted : .denied
    return grants
  }

  var level: Float = 0
  /// What the microphone hears next in a discussion, a tenth of a second at a time.
  var stream: [[Float]] = []
  private(set) var cancelsEcho = false

  func start(cancellingEcho: Bool) throws {
    if failsToStart { throw CocoaError(.featureUnsupported) }
    isRecording = true
    cancelsEcho = cancellingEcho
  }

  func takeSamples() -> [Float] {
    stream.isEmpty ? [] : stream.removeFirst()
  }

  func stop() -> [Float] {
    isRecording = false
    return heard
  }
}

/// A speech model that downloads nothing and hears what it is told to.
private final class FakeTranscriber: SpeechTranscribing, @unchecked Sendable {
  private let lock = NSLock()
  private var installed: [DictationModelVariant: Int64] = [:]
  private var _downloadFails = false
  private var _transcript = ""
  private var _requests: [(samples: Int, language: String?, prompt: String)] = []

  init(installed: [DictationModelVariant] = []) {
    for variant in installed { self.installed[variant] = variant.downloadSize }
  }

  var downloadFails: Bool {
    get { lock.withLock { _downloadFails } }
    set { lock.withLock { _downloadFails = newValue } }
  }
  var transcript: String {
    get { lock.withLock { _transcript } }
    set { lock.withLock { _transcript = newValue } }
  }
  var requests: [(samples: Int, language: String?, prompt: String)] {
    lock.withLock { _requests }
  }

  func installedSize(of variant: DictationModelVariant) -> Int64? {
    lock.withLock { installed[variant] }
  }

  func download(
    _ variant: DictationModelVariant, progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    progress(0.5)
    if downloadFails { throw URLError(.notConnectedToInternet) }
    progress(1)
    lock.withLock { installed[variant] = variant.downloadSize }
  }

  func prepare(_ variant: DictationModelVariant) async throws {}

  func transcribe(
    _ samples: [Float], with variant: DictationModelVariant, language: String?, prompt: String
  ) async throws -> String {
    lock.withLock {
      _requests.append((samples.count, language, prompt))
      return _transcript
    }
  }

  func remove(_ variant: DictationModelVariant) async throws {
    lock.withLock { installed[variant] = nil }
  }
}

/// Lets the dictation's tasks run until `condition` holds: a state awaited, never a deadline.
@MainActor
private func until(_ condition: () -> Bool) async {
  for _ in 0..<10_000 where !condition() { await Task.yield() }
}

/// A second of a voice.
private let speech = (0..<16_000).map { 0.2 * sin(Float($0) * 2 * .pi * 220 / 16_000) }

@Suite("Dictation in the composer (#340)")
@MainActor
struct DictationControllerTests {
  private final class Composer {
    var inserted: [String] = []
  }

  private func request(_ composer: Composer, vocabulary: String = "atlas, main")
    -> DictationController.Request
  {
    DictationController.Request(
      owner: ObjectIdentifier(composer), vocabulary: { vocabulary },
      insert: { composer.inserted.append($0) })
  }

  @Test("The model downloaded, a click records and a second inserts what was said")
  func dictates() async {
    let recorder = FakeRecorder()
    recorder.heard = speech
    let transcriber = FakeTranscriber(installed: [.largeTurbo])
    transcriber.transcript = " Ajoute un test. "
    let store = InMemoryDictationSettingsStore(settings: DictationSettings(language: "fr"))
    let dictation = DictationController(
      transcriber: transcriber, recorder: recorder, store: store)
    let composer = Composer()

    dictation.toggle(request(composer))
    await until { dictation.phase == .recording }
    #expect(dictation.phase == .recording)
    #expect(recorder.isRecording)
    #expect(dictation.concerns(ObjectIdentifier(composer)))

    dictation.toggle(request(composer))
    await until { dictation.phase == .idle }
    #expect(!recorder.isRecording)
    #expect(composer.inserted == ["Ajoute un test."])
    #expect(transcriber.requests.map(\.language) == ["fr"])
    #expect(transcriber.requests.map(\.prompt) == ["atlas, main"])
    #expect(!dictation.concerns(ObjectIdentifier(composer)))
  }

  @Test("Without the model, the download is offered; ready, the user is told and clicks again")
  func offersDownload() async {
    let recorder = FakeRecorder()
    let transcriber = FakeTranscriber()
    let dictation = DictationController(
      transcriber: transcriber, recorder: recorder, store: InMemoryDictationSettingsStore())
    var readyCount = 0
    dictation.modelDidBecomeReady = { readyCount += 1 }
    let composer = Composer()
    #expect(!dictation.isModelInstalled)

    dictation.toggle(request(composer))
    #expect(dictation.phase == .offeringDownload)
    #expect(!recorder.isRecording)

    dictation.acceptDownload()
    await until { dictation.isReadyToDictate }
    // Minutes may have gone by: nothing records until the user clicks again.
    #expect(dictation.phase == .idle)
    #expect(!recorder.isRecording)
    #expect(readyCount == 1)
    #expect(dictation.concerns(ObjectIdentifier(composer)))
    #expect(dictation.installedSizes[.largeTurbo] == DictationModelVariant.largeTurbo.downloadSize)

    dictation.toggle(request(composer))
    await until { dictation.phase == .recording }
    #expect(recorder.isRecording)
    #expect(!dictation.isReadyToDictate)
  }

  @Test("Declined, the offer goes and nothing is downloaded")
  func declinesDownload() {
    let transcriber = FakeTranscriber()
    let dictation = DictationController(
      transcriber: transcriber, recorder: FakeRecorder(), store: InMemoryDictationSettingsStore())
    let composer = Composer()

    dictation.toggle(request(composer))
    dictation.cancel()
    #expect(dictation.phase == .idle)
    #expect(!dictation.concerns(ObjectIdentifier(composer)))
    #expect(!dictation.isModelInstalled)
  }

  @Test("A download that fails says so to the composer that asked")
  func downloadFails() async {
    let transcriber = FakeTranscriber()
    transcriber.downloadFails = true
    let dictation = DictationController(
      transcriber: transcriber, recorder: FakeRecorder(), store: InMemoryDictationSettingsStore())
    let composer = Composer()

    dictation.toggle(request(composer))
    dictation.acceptDownload()
    await until { dictation.problem != nil }
    #expect(dictation.problem == .downloadFailed)
    #expect(dictation.phase == .idle)
    #expect(dictation.concerns(ObjectIdentifier(composer)))

    dictation.dismissProblem()
    #expect(!dictation.concerns(ObjectIdentifier(composer)))
  }

  @Test("A silence inserts nothing, is never given to the model, and is said")
  func silence() async {
    let recorder = FakeRecorder()
    recorder.heard = [Float](repeating: 0, count: 32_000)
    let transcriber = FakeTranscriber(installed: [.largeTurbo])
    transcriber.transcript = "Sous-titres réalisés par la communauté d'Amara.org"
    let dictation = DictationController(
      transcriber: transcriber, recorder: recorder, store: InMemoryDictationSettingsStore())
    let composer = Composer()

    dictation.toggle(request(composer))
    await until { dictation.phase == .recording }
    dictation.toggle(request(composer))
    await until { dictation.problem != nil }
    #expect(dictation.problem == .nothingHeard)
    #expect(composer.inserted.isEmpty)
    #expect(transcriber.requests.isEmpty)
  }

  @Test("A composer put away lets its recording go: the microphone is never left open")
  func releasedWhileRecording() async {
    let recorder = FakeRecorder()
    recorder.heard = speech
    let dictation = DictationController(
      transcriber: FakeTranscriber(installed: [.largeTurbo]), recorder: recorder,
      store: InMemoryDictationSettingsStore())
    let composer = Composer()
    let other = Composer()

    dictation.toggle(request(composer))
    await until { dictation.phase == .recording }
    dictation.release(ObjectIdentifier(other))
    #expect(recorder.isRecording)

    dictation.release(ObjectIdentifier(composer))
    #expect(!recorder.isRecording)
    #expect(dictation.phase == .idle)
    #expect(!dictation.isBusy(for: ObjectIdentifier(other)))
  }

  @Test("A composer put away during the download lets it finish, and nothing records after")
  func releasedWhileDownloading() async {
    let recorder = FakeRecorder()
    let dictation = DictationController(
      transcriber: FakeTranscriber(), recorder: recorder, store: InMemoryDictationSettingsStore())
    let composer = Composer()

    dictation.toggle(request(composer))
    dictation.acceptDownload()
    dictation.release(ObjectIdentifier(composer))
    await until { dictation.isModelInstalled && dictation.phase == .idle }
    #expect(dictation.isModelInstalled)
    #expect(dictation.phase == .idle)
    #expect(!recorder.isRecording)
    #expect(dictation.owner == nil)
    #expect(!dictation.isReadyToDictate)
  }

  @Test("A composer put away while the system asks about the microphone records nothing")
  func releasedWhileAsked() async {
    let recorder = FakeRecorder()
    recorder.access = .undetermined
    let dictation = DictationController(
      transcriber: FakeTranscriber(installed: [.largeTurbo]), recorder: recorder,
      store: InMemoryDictationSettingsStore())
    let composer = Composer()

    dictation.toggle(request(composer))
    dictation.release(ObjectIdentifier(composer))
    await until { recorder.access == .granted }
    for _ in 0..<100 { await Task.yield() }
    #expect(!recorder.isRecording)
    #expect(dictation.phase == .idle)
    #expect(!dictation.isBusy(for: ObjectIdentifier(Composer())))
  }

  @Test("A second click on Stop transcribes once")
  func doubleStop() async {
    let recorder = FakeRecorder()
    recorder.heard = speech
    let transcriber = FakeTranscriber(installed: [.largeTurbo])
    transcriber.transcript = "Fix the build."
    let dictation = DictationController(
      transcriber: transcriber, recorder: recorder, store: InMemoryDictationSettingsStore())
    let composer = Composer()

    dictation.toggle(request(composer))
    await until { dictation.phase == .recording }
    dictation.toggle(request(composer))
    dictation.toggle(request(composer))
    await until { dictation.phase == .idle }
    #expect(composer.inserted == ["Fix the build."])
    #expect(transcriber.requests.count == 1)
    #expect(dictation.problem == nil)
  }

  @Test("Escape throws the recording away")
  func cancelsRecording() async {
    let recorder = FakeRecorder()
    recorder.heard = speech
    let transcriber = FakeTranscriber(installed: [.largeTurbo])
    let dictation = DictationController(
      transcriber: transcriber, recorder: recorder, store: InMemoryDictationSettingsStore())
    let composer = Composer()

    dictation.toggle(request(composer))
    await until { dictation.phase == .recording }
    dictation.cancel()
    #expect(dictation.phase == .idle)
    #expect(!recorder.isRecording)
    #expect(composer.inserted.isEmpty)
    #expect(transcriber.requests.isEmpty)
  }

  @Test("The microphone refused, now or before, is said and nothing records")
  func microphoneRefused() async {
    let recorder = FakeRecorder()
    recorder.access = .undetermined
    recorder.grants = false
    let dictation = DictationController(
      transcriber: FakeTranscriber(installed: [.largeTurbo]), recorder: recorder,
      store: InMemoryDictationSettingsStore())
    let composer = Composer()

    dictation.toggle(request(composer))
    await until { dictation.problem != nil }
    #expect(dictation.problem == .microphoneDenied)
    #expect(!recorder.isRecording)

    dictation.dismissProblem()
    dictation.toggle(request(composer))
    await until { dictation.problem != nil }
    #expect(dictation.problem == .microphoneDenied)
  }

  @Test("No microphone to record from is said")
  func noMicrophone() async {
    let recorder = FakeRecorder()
    recorder.failsToStart = true
    let dictation = DictationController(
      transcriber: FakeTranscriber(installed: [.largeTurbo]), recorder: recorder,
      store: InMemoryDictationSettingsStore())

    dictation.toggle(request(Composer()))
    await until { dictation.problem != nil }
    #expect(dictation.problem == .noMicrophone)
    #expect(dictation.phase == .idle)
  }

  @Test("While one composer records, another waits")
  func oneAtATime() async {
    let recorder = FakeRecorder()
    let dictation = DictationController(
      transcriber: FakeTranscriber(installed: [.largeTurbo]), recorder: recorder,
      store: InMemoryDictationSettingsStore())
    let first = Composer()
    let second = Composer()

    dictation.toggle(request(first))
    await until { dictation.phase == .recording }
    #expect(dictation.isBusy(for: ObjectIdentifier(second)))
    #expect(!dictation.isBusy(for: ObjectIdentifier(first)))

    dictation.toggle(request(second))
    #expect(dictation.phase == .recording)
    #expect(dictation.concerns(ObjectIdentifier(first)))
    #expect(!dictation.concerns(ObjectIdentifier(second)))
  }

  @Test("Settings: the choice is kept, a model downloaded or deleted from there")
  func settings() async {
    let store = InMemoryDictationSettingsStore()
    let transcriber = FakeTranscriber(installed: [.largeTurbo])
    let dictation = DictationController(
      transcriber: transcriber, recorder: FakeRecorder(), store: store)

    dictation.settings.variant = .small
    dictation.settings.language = "de"
    #expect(store.settings == DictationSettings(variant: .small, language: "de"))
    #expect(!dictation.isModelInstalled)

    dictation.downloadSelectedModel()
    await until { dictation.phase == .idle && dictation.isModelInstalled }
    #expect(dictation.installedSizes.keys.sorted { $0.rawValue < $1.rawValue } == [
      .largeTurbo, .small,
    ])
    #expect(dictation.owner == nil)

    await dictation.removeModel(.largeTurbo)
    #expect(dictation.installedSizes.keys.map(\.self) == [.small])
  }
}


/// A tenth of a second of silence, and of a voice.
private let silentTenth = [Float](repeating: 0, count: 1_600)
private let voicedTenth = (0..<1_600).map { 0.2 * sin(Float($0) * 2 * .pi * 220 / 16_000) }

@Suite("The discussion (#357)")
@MainActor
struct DiscussionTests {
  private final class Composer {
    var sent: [String] = []
    var interrupted = 0
    var inserted: [String] = []
  }

  private func request(_ composer: Composer) -> DictationController.Request {
    var request = DictationController.Request(
      owner: ObjectIdentifier(composer), vocabulary: { "" },
      insert: { composer.inserted.append($0) })
    request.send = { composer.sent.append($0) }
    request.interrupt = { composer.interrupted += 1 }
    return request
  }

  /// A press is a click however long the machine takes, unless `holds`.
  private func controller(
    _ recorder: FakeRecorder, _ transcriber: FakeTranscriber, holds: Bool = false
  ) -> DictationController {
    let dictation = DictationController(
      transcriber: transcriber, recorder: recorder, store: InMemoryDictationSettingsStore())
    dictation.holdThreshold = holds ? 0 : 3_600
    return dictation
  }

  @Test("A click starts the discussion: the microphone stays open, echo cancelled")
  func clickStarts() async {
    let recorder = FakeRecorder()
    let dictation = controller(recorder, FakeTranscriber(installed: [.largeTurbo]))
    let composer = Composer()

    dictation.pressBegan(request(composer))
    await until { dictation.phase == .recording }
    dictation.pressEnded(request(composer))
    #expect(dictation.phase == .discussing)
    #expect(recorder.isRecording)
    #expect(recorder.cancelsEcho)

    // A second click ends it.
    dictation.pressBegan(request(composer))
    dictation.pressEnded(request(composer))
    #expect(dictation.phase == .idle)
    #expect(!recorder.isRecording)
  }

  @Test("A sentence ended by a pause is transcribed and sent")
  func sendsSentences() async {
    let recorder = FakeRecorder()
    recorder.stream =
      Array(repeating: silentTenth, count: 5) + Array(repeating: voicedTenth, count: 8)
      + Array(repeating: silentTenth, count: 14)
    let transcriber = FakeTranscriber(installed: [.largeTurbo])
    transcriber.transcript = "Ouvre la PR en brouillon."
    let dictation = controller(recorder, transcriber)
    let composer = Composer()

    dictation.pressBegan(request(composer))
    await until { dictation.phase == .recording }
    dictation.pressEnded(request(composer))
    for _ in 0..<60 where composer.sent.isEmpty {
      try? await Task.sleep(for: .milliseconds(50))
    }
    #expect(composer.sent == ["Ouvre la PR en brouillon."])
    #expect(dictation.phase == .discussing)
    dictation.endDiscussion()
  }

  @Test("« Stop » said in a discussion interrupts the agent instead of being sent")
  func stopInterrupts() async {
    let recorder = FakeRecorder()
    recorder.stream =
      Array(repeating: voicedTenth, count: 5) + Array(repeating: silentTenth, count: 14)
    let transcriber = FakeTranscriber(installed: [.largeTurbo])
    transcriber.transcript = "Stop !"
    let dictation = controller(recorder, transcriber)
    let composer = Composer()

    dictation.pressBegan(request(composer))
    await until { dictation.phase == .recording }
    dictation.pressEnded(request(composer))
    for _ in 0..<60 where composer.interrupted == 0 {
      try? await Task.sleep(for: .milliseconds(50))
    }
    #expect(composer.interrupted == 1)
    #expect(composer.sent.isEmpty)
    dictation.endDiscussion()
  }

  @Test("A held press dictates into the draft, as before")
  func holdDictates() async {
    let recorder = FakeRecorder()
    recorder.heard = speech
    let transcriber = FakeTranscriber(installed: [.largeTurbo])
    transcriber.transcript = "Fix the build."
    let dictation = controller(recorder, transcriber, holds: true)
    let composer = Composer()

    dictation.pressBegan(request(composer))
    await until { dictation.phase == .recording }
    dictation.pressEnded(request(composer))
    await until { dictation.phase == .idle }
    #expect(composer.inserted == ["Fix the build."])
    #expect(composer.sent.isEmpty)
  }

  @Test("Escape, or the composer put away, ends the discussion")
  func ends() async {
    let recorder = FakeRecorder()
    let dictation = controller(recorder, FakeTranscriber(installed: [.largeTurbo]))
    let composer = Composer()

    dictation.pressBegan(request(composer))
    await until { dictation.phase == .recording }
    dictation.pressEnded(request(composer))
    dictation.release(ObjectIdentifier(composer))
    #expect(dictation.phase == .idle)
    #expect(!recorder.isRecording)
  }
}

@Suite("The wave of a dictation (#357)")
@MainActor
struct DictationWaveTests {
  @Test("While a dictation records, the level follows the microphone; it falls back once done")
  func followsTheMicrophone() async {
    let recorder = FakeRecorder()
    recorder.heard = speech
    let transcriber = FakeTranscriber(installed: [.largeTurbo])
    let dictation = DictationController(
      transcriber: transcriber, recorder: recorder, store: InMemoryDictationSettingsStore())
    final class Composer {}
    let composer = Composer()
    let request = DictationController.Request(
      owner: ObjectIdentifier(composer), vocabulary: { "" }, insert: { _ in })

    dictation.toggle(request)
    await until { dictation.phase == .recording }
    recorder.level = 0.2
    for _ in 0..<40 where dictation.level == 0 { try? await Task.sleep(for: .milliseconds(25)) }
    #expect(dictation.level == 0.2)

    dictation.toggle(request)
    await until { dictation.phase == .idle }
    for _ in 0..<40 where dictation.level != 0 { try? await Task.sleep(for: .milliseconds(25)) }
    #expect(dictation.level == 0)
  }
}
