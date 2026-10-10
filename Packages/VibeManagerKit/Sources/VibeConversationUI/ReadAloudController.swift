import Foundation
import Observation
import SwiftUI
import VibeApplication

/// The agent's answers read aloud (#357), by a voice model on this Mac.
///
/// One for the whole application: one voice at a time — reading another answer stops the one
/// being read. The model is downloaded from Settings; ready, it reads nothing by itself. In the
/// audio mode, the answers that arrive in the conversation on screen are read one after the other.
@MainActor
@Observable
public final class ReadAloudController {
  public enum Phase: Equatable, Sendable {
    case idle
    case downloading(fraction: Double)
    /// Loaded — compiled for this Mac, the first time.
    case preparing
    /// Loading the model before reading the answer of this identifier.
    case loading(id: String)
    /// Reading the answer of this identifier aloud.
    case reading(id: String)
  }

  public enum Problem: Equatable, Sendable {
    case downloadFailed
    case readingFailed
  }

  public private(set) var phase = Phase.idle
  public private(set) var problem: Problem?
  /// What the model weighs on disk; `nil` when it is not downloaded.
  public private(set) var installedSize: Int64?
  public var downloadSize: Int64 { synthesizer.downloadSize }

  public var settings: SpeechSettings {
    didSet {
      guard settings != oldValue else { return }
      store.settings = settings
      // The audio mode turned off: what it was reading, and what it was going to, stops.
      if oldValue.readsAnswers, !settings.readsAnswers {
        queue = []
        stop()
      }
      // Another voice or language: prepared now, rather than at the next answer.
      if settings.voice != oldValue.voice || settings.language != oldValue.language, isWarm {
        isWarm = false
        warmUp()
      }
    }
  }

  /// The conversation in a discussion (#357): its answers are read as they arrive, whatever the
  /// audio mode.
  public var readsConversation: ObjectIdentifier?

  /// Opens Settings on the page where the model is downloaded: asked to read without it.
  @ObservationIgnored public var showSettings: (() -> Void)?
  /// Called once the model is downloaded and prepared: minutes after it was asked for.
  @ObservationIgnored public var modelDidBecomeReady: (() -> Void)?

  @ObservationIgnored private let synthesizer: any SpeechSynthesizing
  @ObservationIgnored private let store: any SpeechSettingsStore
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var isWarm = false
  @ObservationIgnored private var warming: Task<Void, Never>?
  /// The answers the audio mode will read next, in their order.
  @ObservationIgnored private var queue: [(id: String, text: String)] = []
  /// The answers each conversation already had: only the ones after are new.
  @ObservationIgnored private var seen: [ObjectIdentifier: Set<String>] = [:]

  public init(synthesizer: any SpeechSynthesizing, store: any SpeechSettingsStore) {
    self.synthesizer = synthesizer
    self.store = store
    settings = store.settings
    installedSize = synthesizer.installedSize()
  }

  public var isModelInstalled: Bool { installedSize != nil }

  /// Whether this answer is being read, or about to be: its button stops it.
  public func isReading(_ id: String) -> Bool {
    phase == .reading(id: id) || phase == .loading(id: id)
  }

  public func isLoading(_ id: String) -> Bool { phase == .loading(id: id) }

  public var isReading: Bool {
    switch phase {
    case .reading, .loading: true
    case .idle, .downloading, .preparing: false
    }
  }

  public var isLoading: Bool {
    if case .loading = phase { return true }
    return false
  }

  /// Loads the model in the background, once, so that the first answer read does not wait for
  /// it: its compilation for this Mac takes minutes the first time. Called when a conversation
  /// comes on screen.
  public func warmUp() {
    guard isModelInstalled, !isWarm, phase == .idle else { return }
    isWarm = true
    let settings = settings
    warming = Task { [synthesizer] in
      try? await synthesizer.prepare(voice: settings.voice, language: settings.language)
    }
  }

  /// The answers of a conversation, as they are now (#357). Those it did not have before are read
  /// in the audio mode, one after the other, if the conversation is on screen; the ones it had
  /// when first followed never are — the audio mode reads what arrives, not the history.
  public func follow(
    _ answers: [(id: String, text: String)], in conversation: ObjectIdentifier, isOnScreen: Bool
  ) {
    let known = seen[conversation]
    seen[conversation, default: []].formUnion(answers.map(\.id))
    guard let known, isOnScreen, isModelInstalled,
      settings.readsAnswers || readsConversation == conversation
    else { return }
    for answer in answers where !known.contains(answer.id) {
      if isReading || !queue.isEmpty {
        queue.append(answer)
      } else {
        start(answer.text, id: answer.id)
      }
    }
  }

  /// The conversation is let go of: what it had is forgotten with it.
  public func forget(_ conversation: ObjectIdentifier) {
    seen[conversation] = nil
  }

  /// Reads the answer `markdown` aloud, its code left out; another being read stops first. Without
  /// the model, Settings opens where it is downloaded.
  public func read(_ markdown: String, id: String) {
    guard isModelInstalled else {
      showSettings?()
      return
    }
    // A reading asked for takes the place of the audio mode's.
    queue = []
    start(markdown, id: id)
  }

  private func start(_ markdown: String, id: String) {
    switch phase {
    case .downloading, .preparing: return
    case .idle, .reading, .loading: break
    }
    task?.cancel()
    problem = nil
    let text = SpeechText.readable(fromMarkdown: markdown)
    guard !text.isEmpty else { return readNext() }
    phase = .loading(id: id)
    isWarm = true
    let settings = settings
    task = Task {
      do {
        try await synthesizer.prepare()
        guard !Task.isCancelled else { return }
        phase = .reading(id: id)
        try await synthesizer.speak(text, voice: settings.voice, language: settings.language)
      } catch {
        if !Task.isCancelled { problem = .readingFailed }
      }
      // A reading stopped for another one leaves its place to it.
      guard !Task.isCancelled, isReading(id) else { return }
      phase = .idle
      readNext()
    }
  }

  /// The next answer the audio mode waits to read, if any.
  private func readNext() {
    guard !queue.isEmpty else { return }
    let next = queue.removeFirst()
    start(next.text, id: next.id)
  }

  /// Stops the voice at once, and what the audio mode was going to read with it.
  public func stop() {
    queue = []
    guard isReading else { return }
    task?.cancel()
    task = nil
    phase = .idle
  }

  /// Settings: the model downloaded and prepared. Ready, it is said, and nothing is read.
  public func downloadModel() {
    guard phase == .idle else { return }
    problem = nil
    phase = .downloading(fraction: 0)
    task = Task {
      do {
        try await synthesizer.download { fraction in
          Task { @MainActor in self.downloadProgressed(fraction) }
        }
      } catch {
        installedSize = synthesizer.installedSize()
        phase = .idle
        problem = .downloadFailed
        return
      }
      installedSize = synthesizer.installedSize()
      phase = .idle
      modelDidBecomeReady?()
    }
  }

  private func downloadProgressed(_ fraction: Double) {
    guard case .downloading = phase else { return }
    phase = fraction >= 1 ? .preparing : .downloading(fraction: fraction)
  }

  public func removeModel() async {
    guard phase == .idle else { return }
    try? await synthesizer.remove()
    installedSize = synthesizer.installedSize()
  }
}

extension EnvironmentValues {
  /// The application's reading aloud; `nil` where there is none — before macOS 15, or in a view
  /// out of a conversation.
  @Entry public var readAloud: ReadAloudController?
}

/// The voice reading an answer, above the conversation, with the way to stop it.
struct ReadingAloudPill: View {
  let readAloud: ReadAloudController
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    Button {
      readAloud.stop()
    } label: {
      HStack(spacing: 8) {
        if readAloud.isLoading {
          ProgressView().controlSize(.mini)
          Text("Preparing the voice…", bundle: .module)
        } else {
          Image(systemName: "speaker.wave.2.fill")
            .symbolEffect(.variableColor.iterative, options: .repeating)
          Text("Reading aloud", bundle: .module)
        }
        Image(systemName: "stop.fill").font(.system(size: 9))
      }
      .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5), weight: .semibold))
      .foregroundStyle(theme.text.color)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(theme.raised.color, in: Capsule())
      .overlay(Capsule().stroke(theme.border.color))
      .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("Stop Reading", bundle: .module))
    .help(Text("Stop Reading", bundle: .module))
    .padding(.top, 10)
  }
}

