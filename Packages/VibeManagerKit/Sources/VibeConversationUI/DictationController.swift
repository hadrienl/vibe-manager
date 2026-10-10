import Foundation
import OSLog
import Observation
import VibeApplication

/// Dictation in the composer (#340): the microphone heard, Whisper run on this Mac, the text put in
/// the draft — never sent.
///
/// One for the whole application: one model loaded, one microphone. A composer asks for it and
/// owns it until its text is inserted; the others wait. The model is downloaded the first time,
/// once the user agreed. Ready, it records nothing by itself: the user, who may have turned to
/// something else meanwhile, is told, and clicks the microphone again.
@MainActor
@Observable
public final class DictationController {
  public enum Phase: Equatable, Sendable {
    case idle
    /// The model is not on this Mac: the composer asks whether to download it.
    case offeringDownload
    case downloading(fraction: Double)
    /// Loaded — compiled for this Mac, the first time.
    case preparing
    case recording
    case transcribing
    /// The discussion (#357): the microphone open, sentences sent as they end.
    case discussing
  }

  /// Where a discussion is, as the composer says it.
  public enum DiscussionState: Equatable, Sendable {
    /// Waiting for the user to speak.
    case listening
    /// The user is speaking.
    case hearing
    /// A sentence is being transcribed.
    case transcribing
    case agentWorking
    /// The voice reads an answer: speaking cuts it.
    case agentSpeaking
  }

  /// What stopped a dictation, said by the composer that asked until it is dismissed.
  public enum Problem: Equatable, Sendable {
    case microphoneDenied
    case noMicrophone
    case downloadFailed
    /// Nothing louder than the room was heard: no text, rather than one Whisper made up.
    case nothingHeard
    case transcriptionFailed
  }

  /// The composer a dictation is asked from, and what it does with the text.
  public struct Request {
    public let owner: ObjectIdentifier
    /// The words the speaker is likely to say: read while the user speaks.
    public let vocabulary: @MainActor () async -> String
    public let insert: @MainActor (String) -> Void
    /// Sends a sentence of the discussion to the agent; `nil` where there is no agent to send to.
    public var send: (@MainActor (String) async -> Void)?
    /// Interrupts the agent's turn: « stop » said in a discussion.
    public var interrupt: (@MainActor () async -> Void)?
    /// Whether the agent is at work, for the discussion to say so.
    public var isAgentWorking: @MainActor () -> Bool = { false }

    public init(
      owner: ObjectIdentifier, vocabulary: @escaping @MainActor () async -> String,
      insert: @escaping @MainActor (String) -> Void
    ) {
      self.owner = owner
      self.vocabulary = vocabulary
      self.insert = insert
    }
  }

  public private(set) var phase = Phase.idle
  public private(set) var problem: Problem?
  /// The composer the phase or the problem belongs to; `nil` for a download asked from Settings.
  public private(set) var owner: ObjectIdentifier?
  /// The model the owner asked for is ready: its composer says so until the next click.
  public private(set) var isReadyToDictate = false
  /// Called once a model is downloaded and prepared: the application tells the user, who may be
  /// elsewhere — a download and its preparation take minutes.
  @ObservationIgnored public var modelDidBecomeReady: (() -> Void)?
  /// Whether the model is loaded in this run: until it is, the first transcription waits for its
  /// compilation for this Mac — minutes, the first time a copy of the application loads it.
  public private(set) var isModelReady = false
  /// Where the discussion is; meaningful while the phase is `.discussing`.
  public private(set) var discussion = DiscussionState.listening
  /// How loud the microphone is now, between 0 and about 0.3: the wave the composer draws.
  public private(set) var level: Float = 0
  /// The voice reading the answers: the discussion reads what arrives, and stops it when the user
  /// speaks over it.
  @ObservationIgnored public weak var readAloud: ReadAloudController?
  /// What each model downloaded weighs on disk.
  public private(set) var installedSizes: [DictationModelVariant: Int64] = [:]

  public var settings: DictationSettings {
    didSet {
      guard settings != oldValue else { return }
      store.settings = settings
      if settings.variant != oldValue.variant {
        isModelReady = false
        isWarming = false
      }
    }
  }

  @ObservationIgnored private let transcriber: any SpeechTranscribing
  @ObservationIgnored private let recorder: any AudioRecording
  @ObservationIgnored private let store: any DictationSettingsStore
  @ObservationIgnored private var request: Request?
  @ObservationIgnored private var download: Task<Void, Never>?
  /// Which download is the current one: one cancelled that still finishes is told apart.
  @ObservationIgnored private var downloadGeneration = 0
  /// Which click a recording about to start answers: the system's question about the microphone
  /// can stay on screen while the composer is put away, or another one clicked.
  @ObservationIgnored private var attempt = 0
  /// The prompt of the recording under way, read while the user speaks.
  @ObservationIgnored private var vocabulary: Task<String, Never>?
  /// When the microphone was pressed: a press shorter than this is a click.
  @ObservationIgnored private var pressedAt: Date?
  /// A press let go of before the recording it asked for had started.
  @ObservationIgnored private var earlyRelease: EarlyRelease?
  private enum EarlyRelease { case click, hold }
  @ObservationIgnored private var detector = UtteranceDetector()
  @ObservationIgnored private var listening: Task<Void, Never>?
  /// The level of a dictation, read for its wave.
  @ObservationIgnored private var metering: Task<Void, Never>?
  @ObservationIgnored private var isWarming = false
  @ObservationIgnored private var ticks = 0
  private static let log = Logger(subsystem: "eu.hadrien.VibeManager", category: "voice")
  /// The sentences of the discussion, transcribed and sent one after the other.
  @ObservationIgnored private var sentences: Task<Void, Never>?
  @ObservationIgnored private var pendingSentences = 0

  /// Shorter, a press is a click: it starts or ends the discussion; longer, it dictates.
  /// Changed by the tests only, whose clock runs as the machine allows.
  @ObservationIgnored var holdThreshold: TimeInterval = 0.3

  public init(
    transcriber: any SpeechTranscribing, recorder: any AudioRecording,
    store: any DictationSettingsStore
  ) {
    self.transcriber = transcriber
    self.recorder = recorder
    self.store = store
    settings = store.settings
    refreshInstalledSizes()
  }

  /// Whether the model chosen is on this Mac.
  public var isModelInstalled: Bool { installedSizes[settings.variant] != nil }

  /// Whether a dictation, or what stopped one, belongs to this composer.
  public func concerns(_ owner: ObjectIdentifier) -> Bool {
    self.owner == owner && (phase != .idle || problem != nil || isReadyToDictate)
  }

  /// Whether another composer, or Settings, holds the dictation: this one waits.
  public func isBusy(for owner: ObjectIdentifier) -> Bool {
    phase != .idle && self.owner != owner
  }

  /// The composer's button: starts a dictation, or stops the one it is recording and inserts
  /// what was said.
  public func toggle(_ request: Request) {
    if phase == .recording, owner == request.owner {
      // Stopped now, not when the task runs: a second click must find it stopped.
      let samples = recorder.stop()
      phase = .transcribing
      Task { await finishRecording(samples) }
      return
    }
    guard phase == .idle else { return }
    attempt += 1
    self.request = request
    owner = request.owner
    problem = nil
    isReadyToDictate = false
    guard isModelInstalled else {
      phase = .offeringDownload
      return
    }
    Task { [attempt] in await startRecording(answering: attempt) }
  }

  /// Loads the model in the background, once, when a conversation comes on screen: its first
  /// load in a copy of the application compiles it for this Mac, which takes minutes (#357).
  public func warmUp() {
    guard isModelInstalled, !isWarming, !isModelReady else { return }
    isWarming = true
    let variant = settings.variant
    Task {
      try? await transcriber.prepare(variant)
      isModelReady = true
    }
  }

  /// The microphone pressed — its button, or Space (#357). It listens at once: what is said
  /// before the press is known to be held is kept.
  public func pressBegan(_ request: Request) {
    Self.log.notice("Microphone pressed, \(String(describing: self.phase), privacy: .public)")
    pressedAt = Date()
    // Pressed again while it listens — a gesture the interface repeats — changes nothing: only
    // letting go does.
    guard phase == .idle else { return }
    earlyRelease = nil
    toggle(request)
  }

  /// The microphone let go of: held, what was said is inserted in the draft; clicked, the
  /// discussion starts — or ends, if it was on.
  public func pressEnded(_ request: Request) {
    // A release without its press is a click: never a dictation ended by surprise.
    let held = pressedAt.map { Date().timeIntervalSince($0) >= holdThreshold } ?? false
    Self.log.notice(
      "Microphone released, \(held ? "held" : "clicked", privacy: .public), \(String(describing: self.phase), privacy: .public)"
    )
    pressedAt = nil
    guard owner == request.owner else { return }
    switch phase {
    case .discussing:
      if !held { endDiscussion() }
    case .recording:
      if held {
        toggle(request)
      } else {
        _ = recorder.stop()
        startDiscussion()
      }
    case .idle:
      // The system still asks about the microphone: the recording starts once it answered.
      if self.request != nil { earlyRelease = held ? .hold : .click }
    case .offeringDownload, .downloading, .preparing, .transcribing:
      break
    }
  }

  private func startDiscussion() {
    Self.log.notice("Discussion started")
    guard let request else { return end() }
    do {
      try recorder.start(cancellingEcho: true)
    } catch {
      return fail(.noMicrophone)
    }
    phase = .discussing
    discussion = .listening
    detector = UtteranceDetector()
    readAloud?.readsConversation = request.owner
    let variant = settings.variant
    Task { try? await transcriber.prepare(variant) }
    vocabulary = Task { await request.vocabulary() }
    listening = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled, phase == .discussing else { return }
        listen()
      }
    }
  }

  /// What the microphone heard in the last tenth of a second: a sentence begun, ended, or the
  /// voice cut by the user speaking over it.
  private func listen() {
    let isSpeaking = readAloud?.isReading == true
    for event in detector.feed(recorder.takeSamples(), whileSpeaking: isSpeaking) {
      switch event {
      case .speechStarted:
        if isSpeaking { readAloud?.stop() }
      case .utterance(let samples):
        queue(samples)
      }
    }
    level = detector.level
    // What the detector makes of the room, once a second: to tune it where it hears wrong.
    ticks += 1
    if ticks % 10 == 0 {
      Self.log.notice(
        "Discussion: level \(self.detector.level, format: .fixed(precision: 3)) room \(self.detector.floor, format: .fixed(precision: 3)) threshold \(self.detector.threshold(whileSpeaking: isSpeaking), format: .fixed(precision: 3)) hearing \(self.detector.isHearingSpeech)"
      )
    }
    discussion =
      if detector.isHearingSpeech { .hearing } else if pendingSentences > 0 {
        .transcribing
      } else if readAloud?.isReading == true {
        .agentSpeaking
      } else if request?.isAgentWorking() == true { .agentWorking } else { .listening }
  }

  /// A sentence to transcribe and send, after those before it.
  private func queue(_ samples: [Float]) {
    guard let request else { return }
    let previous = sentences
    let prompt = vocabulary
    pendingSentences += 1
    sentences = Task {
      await previous?.value
      await say(samples, for: request, prompt: await prompt?.value ?? "")
      pendingSentences -= 1
    }
  }

  /// A sentence of the discussion, transcribed and sent — or « stop », which interrupts the agent.
  /// Sent even once the discussion is over: the last sentence is what ended it.
  private func say(_ samples: [Float], for request: Request, prompt: String) async {
    guard DictationTranscript.containsSpeech(samples) else { return }
    guard
      let text = try? await transcriber.transcribe(
        samples, with: settings.variant, language: settings.language, prompt: prompt)
    else { return }
    let sentence = DictationTranscript.cleaned(text)
    guard !sentence.isEmpty else { return }
    if UtteranceDetector.isStop(sentence) {
      readAloud?.stop()
      await request.interrupt?()
    } else {
      await request.send?(sentence)
    }
  }

  /// The discussion over: the microphone closed, the voice silent. A sentence under way is still
  /// transcribed and sent — the user ended the discussion on it.
  public func endDiscussion() {
    guard phase == .discussing else { return }
    Self.log.notice("Discussion ended")
    listening?.cancel()
    listening = nil
    _ = detector.feed(recorder.stop())
    let last = detector.flush()
    if let last { queue(last) }
    readAloud?.stop()
    if last != nil {
      // The discussion ended on a sentence: its answer is still read.
      readAloud?.readsNextAnswerOnly = true
    } else {
      readAloud?.readsConversation = nil
    }
    level = 0
    end()
  }

  /// The user agreed to download the model.
  public func acceptDownload() {
    guard phase == .offeringDownload else { return }
    downloadModel()
  }

  /// Settings › Dictation: the model chosen, downloaded now, for no dictation in particular.
  public func downloadSelectedModel() {
    guard phase == .idle else { return }
    request = nil
    owner = nil
    problem = nil
    isReadyToDictate = false
    downloadModel()
  }

  private func downloadModel() {
    let variant = settings.variant
    phase = .downloading(fraction: 0)
    downloadGeneration += 1
    let generation = downloadGeneration
    download = Task {
      do {
        try await transcriber.download(variant) { fraction in
          Task { @MainActor in self.downloadProgressed(fraction) }
        }
      } catch {
        refreshInstalledSizes()
        guard generation == downloadGeneration else { return }
        download = nil
        phase = .idle
        problem = .downloadFailed
        return
      }
      guard generation == downloadGeneration else {
        // Cancelled, it went to its end all the same: what it wrote goes, unless the same model is
        // being downloaded again.
        if !isDownloading(variant) { try? await transcriber.remove(variant) }
        refreshInstalledSizes()
        return
      }
      download = nil
      refreshInstalledSizes()
      phase = .idle
      request = nil
      // Never a recording started by itself: the composer that asked says the model is ready.
      isReadyToDictate = owner != nil
      modelDidBecomeReady?()
    }
  }

  private func isDownloading(_ variant: DictationModelVariant) -> Bool {
    switch phase {
    case .downloading, .preparing: settings.variant == variant
    case .idle, .offeringDownload, .recording, .transcribing, .discussing: false
    }
  }

  private func downloadProgressed(_ fraction: Double) {
    guard case .downloading = phase else { return }
    // Downloaded, the model is loaded before the download returns: that is its preparation.
    phase = fraction >= 1 ? .preparing : .downloading(fraction: fraction)
  }

  /// Escape, or the popover closed: a recording is thrown away, an offer declined, a download
  /// stopped. A transcription under way goes to its end.
  public func cancel() {
    switch phase {
    case .recording:
      _ = recorder.stop()
      vocabulary?.cancel()
      vocabulary = nil
      end()
    case .offeringDownload:
      end()
    case .downloading:
      download?.cancel()
      download = nil
      downloadGeneration += 1
      end()
      // What was downloaded is not kept: it would take hundreds of megabytes nobody sees.
      let variant = settings.variant
      Task { [transcriber] in try? await transcriber.remove(variant) }
    case .discussing:
      endDiscussion()
    case .idle, .preparing, .transcribing:
      break
    }
  }

  /// The composer is no longer on screen: its recording is thrown away and its offer withdrawn —
  /// a microphone is never left open behind the user. A download it asked for goes on, and no
  /// recording starts at its end; a transcription under way still inserts its text in the draft.
  public func release(_ owner: ObjectIdentifier) {
    guard self.owner == owner else { return }
    switch phase {
    case .recording, .offeringDownload, .discussing:
      cancel()
    case .downloading, .preparing:
      request = nil
      self.owner = nil
    case .idle:
      // A recording about to start — the system asking about the microphone — never will.
      attempt += 1
      dismissProblem()
    case .transcribing:
      break
    }
  }

  public func dismissProblem() {
    problem = nil
    isReadyToDictate = false
    guard phase == .idle else { return }
    owner = nil
    request = nil
  }

  /// Settings › Dictation › Delete: the model leaves the disk.
  public func removeModel(_ variant: DictationModelVariant) async {
    guard phase == .idle else { return }
    try? await transcriber.remove(variant)
    refreshInstalledSizes()
  }

  /// - Parameter attempt: the click it answers, counted when it was made.
  private func startRecording(answering attempt: Int) async {
    switch recorder.access {
    case .granted: break
    case .undetermined:
      guard await recorder.requestAccess() else { return fail(.microphoneDenied) }
    case .denied:
      return fail(.microphoneDenied)
    }
    // The composer may have been put away, or another one clicked, while the system asked.
    guard attempt == self.attempt, let request, owner == request.owner, phase == .idle else {
      return
    }
    do {
      try recorder.start()
    } catch {
      return fail(.noMicrophone)
    }
    phase = .recording
    switch earlyRelease {
    case .click:
      earlyRelease = nil
      _ = recorder.stop()
      return startDiscussion()
    case .hold:
      // Let go of while the system asked: there is nothing to dictate.
      earlyRelease = nil
      _ = recorder.stop()
      return end()
    case nil:
      break
    }
    // The wave of the dictation follows the voice, twenty times a second.
    metering = Task {
      while !Task.isCancelled, phase == .recording {
        level = recorder.level
        try? await Task.sleep(for: .milliseconds(50))
      }
      if phase != .discussing { level = 0 }
    }
    // Loaded, and the prompt read, while the user speaks: both are ready, or nearly, when they
    // stop.
    let variant = settings.variant
    Task { try? await transcriber.prepare(variant) }
    vocabulary = Task { await request.vocabulary() }
  }

  private func finishRecording(_ samples: [Float]) async {
    Self.log.notice(
      "Dictation ended: \(Double(samples.count) / 16_000, format: .fixed(precision: 1)) s heard")
    // A transcription that never ends is said, rather than shown under way for ever — counted
    // once the model is loaded, whose first load takes minutes.
    let watchdog = Task { [attempt] in
      while !isModelReady, !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
      try? await Task.sleep(for: .seconds(60))
      guard !Task.isCancelled, phase == .transcribing, self.attempt == attempt else { return }
      fail(.transcriptionFailed)
    }
    defer { watchdog.cancel() }
    let prompt = await vocabulary?.value ?? ""
    vocabulary = nil
    guard let request else { return end() }
    // Nothing said is nothing inserted: a silence given to Whisper comes back as a made-up line.
    guard DictationTranscript.containsSpeech(samples) else { return fail(.nothingHeard) }
    do {
      let text = try await transcriber.transcribe(
        samples, with: settings.variant, language: settings.language, prompt: prompt)
      isModelReady = true
      let cleaned = DictationTranscript.cleaned(text)
      if !cleaned.isEmpty { request.insert(cleaned) }
      end()
    } catch {
      fail(.transcriptionFailed)
    }
  }

  private func fail(_ problem: Problem) {
    phase = .idle
    request = nil
    self.problem = problem
  }

  private func end() {
    phase = .idle
    request = nil
    owner = nil
  }

  private func refreshInstalledSizes() {
    installedSizes = Dictionary(
      uniqueKeysWithValues: DictationModelVariant.allCases.compactMap { variant in
        transcriber.installedSize(of: variant).map { (variant, $0) }
      })
  }
}
