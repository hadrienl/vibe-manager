import Foundation
import Observation
import SwiftUI
import VibeApplication

/// The agent's answers read aloud (#357), by a voice model on this Mac.
///
/// One for the whole application: one voice at a time — reading another answer stops the one
/// being read. The model is downloaded from Settings; ready, it reads nothing by itself.
@MainActor
@Observable
public final class ReadAloudController {
  public enum Phase: Equatable, Sendable {
    case idle
    case downloading(fraction: Double)
    /// Loaded — compiled for this Mac, the first time.
    case preparing
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
    }
  }

  /// Opens Settings on the page where the model is downloaded: asked to read without it.
  @ObservationIgnored public var showSettings: (() -> Void)?
  /// Called once the model is downloaded and prepared: minutes after it was asked for.
  @ObservationIgnored public var modelDidBecomeReady: (() -> Void)?

  @ObservationIgnored private let synthesizer: any SpeechSynthesizing
  @ObservationIgnored private let store: any SpeechSettingsStore
  @ObservationIgnored private var task: Task<Void, Never>?

  public init(synthesizer: any SpeechSynthesizing, store: any SpeechSettingsStore) {
    self.synthesizer = synthesizer
    self.store = store
    settings = store.settings
    installedSize = synthesizer.installedSize()
  }

  public var isModelInstalled: Bool { installedSize != nil }

  public func isReading(_ id: String) -> Bool { phase == .reading(id: id) }

  public var isReading: Bool {
    if case .reading = phase { return true }
    return false
  }

  /// Reads the answer `markdown` aloud, its code left out; another being read stops first. Without
  /// the model, Settings opens where it is downloaded.
  public func read(_ markdown: String, id: String) {
    guard isModelInstalled else {
      showSettings?()
      return
    }
    switch phase {
    case .downloading, .preparing: return
    case .idle, .reading: break
    }
    task?.cancel()
    problem = nil
    let text = SpeechText.readable(fromMarkdown: markdown)
    guard !text.isEmpty else { return }
    phase = .reading(id: id)
    let settings = settings
    task = Task {
      do {
        try await synthesizer.speak(text, voice: settings.voice, language: settings.language)
      } catch {
        if !Task.isCancelled { problem = .readingFailed }
      }
      // A reading stopped for another one leaves its place to it.
      if !Task.isCancelled, phase == .reading(id: id) { phase = .idle }
    }
  }

  /// Stops the voice at once.
  public func stop() {
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
        Image(systemName: "speaker.wave.2.fill")
          .symbolEffect(.variableColor.iterative, options: .repeating)
        Text("Reading aloud", bundle: .module)
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
