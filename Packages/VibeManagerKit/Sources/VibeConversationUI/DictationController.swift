import Foundation
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
    /// The words the speaker is likely to say: read when the recording stops.
    public let vocabulary: @MainActor () -> String
    public let insert: @MainActor (String) -> Void

    public init(
      owner: ObjectIdentifier, vocabulary: @escaping @MainActor () -> String,
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
  /// What each model downloaded weighs on disk.
  public private(set) var installedSizes: [DictationModelVariant: Int64] = [:]

  public var settings: DictationSettings {
    didSet {
      guard settings != oldValue else { return }
      store.settings = settings
    }
  }

  @ObservationIgnored private let transcriber: any SpeechTranscribing
  @ObservationIgnored private let recorder: any AudioRecording
  @ObservationIgnored private let store: any DictationSettingsStore
  @ObservationIgnored private var request: Request?
  @ObservationIgnored private var download: Task<Void, Never>?

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
      Task { await finishRecording() }
      return
    }
    guard phase == .idle else { return }
    self.request = request
    owner = request.owner
    problem = nil
    isReadyToDictate = false
    guard isModelInstalled else {
      phase = .offeringDownload
      return
    }
    Task { await startRecording() }
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
    download = Task {
      do {
        try await transcriber.download(variant) { fraction in
          Task { @MainActor in self.downloadProgressed(fraction) }
        }
      } catch {
        refreshInstalledSizes()
        guard !Task.isCancelled else { return }
        phase = .idle
        problem = .downloadFailed
        return
      }
      download = nil
      refreshInstalledSizes()
      guard !Task.isCancelled else { return }
      phase = .idle
      request = nil
      // Never a recording started by itself: the composer that asked says the model is ready.
      isReadyToDictate = owner != nil
      modelDidBecomeReady?()
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
      end()
    case .offeringDownload:
      end()
    case .downloading:
      download?.cancel()
      download = nil
      end()
      // What was downloaded is not kept: it would take hundreds of megabytes nobody sees.
      let variant = settings.variant
      Task { [transcriber] in try? await transcriber.remove(variant) }
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
    case .recording, .offeringDownload:
      cancel()
    case .downloading, .preparing:
      request = nil
      self.owner = nil
    case .idle:
      dismissProblem()
    case .transcribing:
      break
    }
  }

  public func dismissProblem() {
    problem = nil
    isReadyToDictate = false
    if phase == .idle { owner = nil }
  }

  /// Settings › Dictation › Delete: the model leaves the disk.
  public func removeModel(_ variant: DictationModelVariant) async {
    guard phase == .idle else { return }
    try? await transcriber.remove(variant)
    refreshInstalledSizes()
  }

  private func startRecording() async {
    switch recorder.access {
    case .granted: break
    case .undetermined:
      guard await recorder.requestAccess() else { return fail(.microphoneDenied) }
    case .denied:
      return fail(.microphoneDenied)
    }
    // The user may have cancelled while the system asked.
    guard request != nil, phase == .idle else { return }
    do {
      try recorder.start()
    } catch {
      return fail(.noMicrophone)
    }
    phase = .recording
    // Loaded while the user speaks: the model is ready, or nearly, when they stop.
    let variant = settings.variant
    Task { try? await transcriber.prepare(variant) }
  }

  private func finishRecording() async {
    let samples = recorder.stop()
    guard let request else { return end() }
    // Nothing said is nothing inserted: a silence given to Whisper comes back as a made-up line.
    guard DictationTranscript.containsSpeech(samples) else { return fail(.nothingHeard) }
    phase = .transcribing
    do {
      let text = try await transcriber.transcribe(
        samples, with: settings.variant, language: settings.language,
        prompt: request.vocabulary())
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
