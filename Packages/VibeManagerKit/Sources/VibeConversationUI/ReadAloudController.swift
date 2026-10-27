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
      // The audio mode turned off: what it was reading, and what it was going to, stops — not an
      // answer read by hand, nor a discussion's.
      if oldValue.readsAnswers, !settings.readsAnswers {
        queue.removeAll { $0.conversation != readsConversation }
        if let readsFor, readsFor != readsConversation { stopReading() }
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
  /// The discussion ended on a sentence sent: the answer to it is read — the whole turn of the
  /// agent's, its text before and after its tools — then nothing more.
  public var readsNextAnswerOnly = false {
    didSet { if !readsNextAnswerOnly { isAnswered = false } }
  }
  /// The microphone records a dictation: the audio mode reads nothing — the voice would be
  /// dictated — and reads what arrived meanwhile once it is closed.
  public var isSuspended = false {
    didSet { if !isSuspended, oldValue, !isReading { readNext() } }
  }

  /// Opens Settings on the page where the model is downloaded: asked to read without it.
  @ObservationIgnored public var showSettings: (() -> Void)?
  /// Called once the model is downloaded and prepared: minutes after it was asked for.
  @ObservationIgnored public var modelDidBecomeReady: (() -> Void)?

  @ObservationIgnored private let synthesizer: any SpeechSynthesizing
  @ObservationIgnored private let store: any SpeechSettingsStore
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var isWarm = false
  @ObservationIgnored private var warming: Task<Void, Never>?
  /// Counts the downloads: one cancelled that ends all the same is told apart from the next.
  @ObservationIgnored private var downloadGeneration = 0
  /// The files of a cancelled download, being removed.
  @ObservationIgnored private var removal: Task<Void, Never>?
  /// The answers the audio mode will read next, in their order, with their conversation.
  @ObservationIgnored private var queue: [(id: String, text: String, conversation: ObjectIdentifier)] = []
  /// The answers each conversation already had: only the ones after are new.
  @ObservationIgnored private var seen: [ObjectIdentifier: Set<String>] = [:]
  /// When each conversation came on screen: an answer written before, while it was out of sight,
  /// is not read when it is shown.
  @ObservationIgnored private var shownSince: [ObjectIdentifier: Date] = [:]
  /// The conversation whose answer the audio mode reads now; `nil` for one read by hand.
  @ObservationIgnored private var readsFor: ObjectIdentifier?
  /// An answer arrived after the discussion ended on a sentence: the agent's turn over, it ends.
  @ObservationIgnored private var isAnswered = false

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
  /// in the audio mode, one after the other, if they were written while it was on screen: the
  /// audio mode reads what arrives before the user's eyes — not the history, not what came while
  /// they looked elsewhere. A conversation out of sight stops what it was reading and going to.
  /// - Parameter now: the moment it is told, for the tests.
  public func follow(
    _ answers: [(id: String, text: String, date: Date?)], in conversation: ObjectIdentifier,
    isOnScreen: Bool, now: Date = Date()
  ) {
    let known = seen[conversation]
    seen[conversation, default: []].formUnion(answers.map(\.id))
    let arrived = known.map { known in answers.filter { !known.contains($0.id) } } ?? []
    if readsNextAnswerOnly, readsConversation == conversation, !arrived.isEmpty {
      isAnswered = true
    }
    guard isOnScreen else {
      shownSince[conversation] = nil
      leave(conversation)
      return
    }
    let since = shownSince[conversation] ?? now
    shownSince[conversation] = since
    guard isModelInstalled, settings.readsAnswers || readsConversation == conversation else {
      return
    }
    for answer in arrived where (answer.date ?? now) >= since {
      if isReading || !queue.isEmpty || isSuspended {
        queue.append((answer.id, answer.text, conversation))
      } else {
        start(answer.text, id: answer.id, for: conversation)
      }
    }
  }

  /// The agent's turn is over in this conversation: a discussion ended on a sentence, answered, is
  /// over — what was to be read of its answer still is.
  public func turnEnded(in conversation: ObjectIdentifier) {
    guard readsNextAnswerOnly, readsConversation == conversation, isAnswered else { return }
    readsConversation = nil
    readsNextAnswerOnly = false
  }

  /// The conversation is let go of: what it had is forgotten with it.
  public func forget(_ conversation: ObjectIdentifier) {
    seen[conversation] = nil
    shownSince[conversation] = nil
    leave(conversation)
  }

  /// The conversation out of sight: the audio mode reads nothing more of it.
  private func leave(_ conversation: ObjectIdentifier) {
    queue.removeAll { $0.conversation == conversation }
    if readsFor == conversation { stopReading() }
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
    start(markdown, id: id, for: nil)
  }

  /// - Parameter conversation: the one the audio mode reads for; `nil` for an answer read by hand.
  private func start(_ markdown: String, id: String, for conversation: ObjectIdentifier?) {
    switch phase {
    case .downloading, .preparing: return
    case .idle, .reading, .loading: break
    }
    task?.cancel()
    problem = nil
    let text = SpeechText.readable(fromMarkdown: markdown)
    guard !text.isEmpty else {
      // Nothing to read in it, code alone: the answer read before stops all the same.
      task = nil
      readsFor = nil
      phase = .idle
      return readNext()
    }
    readsFor = conversation
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
      readsFor = nil
      readNext()
    }
  }

  /// The next answer the audio mode waits to read, if any.
  private func readNext() {
    guard !queue.isEmpty, !isSuspended else { return }
    let next = queue.removeFirst()
    start(next.text, id: next.id, for: next.conversation)
  }

  /// Stops the voice at once, and what the audio mode was going to read with it.
  public func stop() {
    queue = []
    stopReading()
  }

  /// The voice silent; what the audio mode waits to read stays.
  private func stopReading() {
    readsFor = nil
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
    downloadGeneration += 1
    let generation = downloadGeneration
    task = Task { [removal] in
      // A download cancelled a moment ago: its files go before the new one writes its own.
      await removal?.value
      do {
        try await synthesizer.download { fraction in
          Task { @MainActor in self.downloadProgressed(fraction) }
        }
      } catch {
        guard generation == downloadGeneration else { return }
        installedSize = synthesizer.installedSize()
        phase = .idle
        problem = .downloadFailed
        return
      }
      guard generation == downloadGeneration else {
        // Cancelled, it went to its end all the same: what it wrote goes, unless the model is
        // being downloaded again.
        if phase == .idle { try? await synthesizer.remove() }
        installedSize = synthesizer.installedSize()
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

  /// Settings: the download stopped, or the preparation that follows it. What was downloaded is
  /// not kept: it would take a gigabyte nobody sees.
  public func cancelDownload() {
    switch phase {
    case .downloading, .preparing: break
    case .idle, .loading, .reading: return
    }
    task?.cancel()
    task = nil
    downloadGeneration += 1
    phase = .idle
    problem = nil
    removal = Task { [synthesizer] in
      try? await synthesizer.remove()
      installedSize = synthesizer.installedSize()
    }
  }

  /// The message of a reading that failed, put away.
  public func dismissProblem() {
    problem = nil
  }

  public func removeModel() async {
    guard phase == .idle else { return }
    // The model loaded in the background is dropped with it, and loaded again once downloaded.
    warming?.cancel()
    warming = nil
    isWarm = false
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

/// A reading that failed, above the conversation: what to do about it, and the way to Settings.
struct ReadingFailedNotice: View {
  let readAloud: ReadAloudController
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(theme.secondaryText.color)
      VStack(alignment: .leading, spacing: 2) {
        Text("The answer could not be read aloud.", bundle: .module)
          .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5), weight: .semibold))
        Text(
          "Try again. If it keeps failing, delete the model in Settings › Voice and download it again.",
          bundle: .module
        )
        .font(theme.interfaceFont(size: appearance.textSize.scaled(11.5)))
        .foregroundStyle(theme.secondaryText.color)
        .fixedSize(horizontal: false, vertical: true)
      }
      Button {
        readAloud.dismissProblem()
        readAloud.showSettings?()
        openSettings()
      } label: {
        Text("Settings", bundle: .module)
      }
      Button {
        readAloud.dismissProblem()
      } label: {
        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Dismiss", bundle: .module))
    }
    .foregroundStyle(theme.text.color)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .frame(maxWidth: 460)
    .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border.color))
    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    .padding(.top, 10)
  }
}

/// The audio mode (#357): each answer that arrives in the conversation on screen is read aloud.
/// A discussion reads them too: it shows on, and stays so until the discussion ends.
struct AudioModeButton: View {
  @Bindable var readAloud: ReadAloudController
  let conversation: ObjectIdentifier
  @Environment(\.conversationTheme) private var theme
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    let isDiscussing =
      readAloud.readsConversation == conversation && !readAloud.readsNextAnswerOnly
    let isOn = readAloud.settings.readsAnswers || isDiscussing
    Button {
      // A discussion reads its answers whatever the mode: nothing to turn off before it ends.
      guard !isDiscussing else { return }
      readAloud.settings.readsAnswers.toggle()
      // Without its model, Settings shows where it is downloaded.
      if readAloud.settings.readsAnswers, !readAloud.isModelInstalled {
        readAloud.showSettings?()
        openSettings()
      }
    } label: {
      Image(systemName: isOn ? "speaker.wave.2.fill" : "speaker.slash")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(isOn ? theme.onAccent.color : theme.text.color)
        .frame(width: 28, height: 28)
        .background(isOn ? theme.accent.color : theme.surface.color, in: Circle())
        .overlay(Circle().stroke(isOn ? Color.clear : theme.border.color))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("Audio Mode", bundle: .module))
    .accessibilityValue(isOn ? Text("On", bundle: .module) : Text("Off", bundle: .module))
    .help(
      isOn
        ? Text("Audio mode on: answers are read as they arrive", bundle: .module)
        : Text("Audio mode: read the answers as they arrive", bundle: .module))
  }
}
