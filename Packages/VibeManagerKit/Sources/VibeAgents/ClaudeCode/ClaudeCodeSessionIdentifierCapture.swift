import Foundation
import VibeApplication
import VibeDomain

/// Stores the identifier a launch assigned to a Claude Code conversation — but only once the
/// CLI has written that conversation down.
///
/// The identifier exists before the conversation does: this app generates it and passes it as
/// `--session-id`. Persisting it at plan time would leave a resume identifier behind on a run
/// that never got as far as a first exchange — a process that failed to start, a pane closed
/// at the trust prompt — and the next launch would then ask the CLI to resume a conversation
/// it has never heard of. So, as for Codex, nothing is written until the transcript proves the
/// conversation is real.
public actor ClaudeCodeSessionIdentifierCapture {
  public static let defaultPersistenceWindow: Duration = .seconds(10)
  public static let defaultTranscriptTimeout: Duration = .seconds(30)
  static let retryInterval: Duration = .milliseconds(200)

  private let sessionID: SessionID
  private let record: RecordAgentResumeIdentifier
  private let transcripts: any ClaudeCodeTranscriptWatching
  private let transcriptTimeout: Duration
  private let persistenceWindow: Duration

  private var assigned: String?
  private var captured: String?
  private var unstored: String?
  private var watcher: Task<Void, Never>?
  private var persister: Task<Void, Never>?

  public init(
    sessionID: SessionID,
    record: RecordAgentResumeIdentifier,
    transcripts: any ClaudeCodeTranscriptWatching = ClaudeCodeTranscriptWatcher(),
    transcriptTimeout: Duration = ClaudeCodeSessionIdentifierCapture.defaultTranscriptTimeout,
    persistenceWindow: Duration = ClaudeCodeSessionIdentifierCapture.defaultPersistenceWindow
  ) {
    self.sessionID = sessionID
    self.record = record
    self.transcripts = transcripts
    self.transcriptTimeout = transcriptTimeout
    self.persistenceWindow = persistenceWindow
  }

  public var assignedIdentifier: String? {
    assigned
  }

  public var identifier: String? {
    captured
  }

  public var unstoredIdentifier: String? {
    unstored
  }

  @discardableResult
  public func record(plan: AgentLaunchPlan) -> String? {
    guard let identifier = ClaudeCodeArgumentBuilder.assignedSessionIdentifier(in: plan.arguments)
    else {
      return nil
    }

    watcher?.cancel()
    persister?.cancel()
    watcher = nil
    persister = nil
    assigned = identifier
    captured = nil
    unstored = nil

    watcher = Task { [weak self] in await self?.storeOnceWritten(identifier) }
    return identifier
  }

  public func settled() async -> String? {
    await watcher?.value
    await persister?.value
    return captured
  }

  public func stop() {
    watcher?.cancel()
    persister?.cancel()
    watcher = nil
    persister = nil
  }

  /// Waits for the conversation to exist, then writes its identifier down.
  ///
  /// A conversation that never appears is a conversation there is nothing to resume, so the
  /// identifier is dropped rather than surfaced: unlike a write that failed, nothing was lost.
  private func storeOnceWritten(_ identifier: String) async {
    let exists = await transcripts.awaitTranscript(
      identifier: identifier,
      timeout: transcriptTimeout
    )
    guard !Task.isCancelled, exists, assigned == identifier else { return }

    switch await persist(identifier) {
    case .kept, .rejected:
      break
    case .retry:
      persister = Task { [weak self] in await self?.keepTrying(identifier) }
    }
  }

  private func keepTrying(_ identifier: String) async {
    let deadline = ContinuousClock.now.advanced(by: persistenceWindow)
    while ContinuousClock.now < deadline {
      do {
        try await Task.sleep(for: Self.retryInterval)
      } catch {
        break
      }
      guard assigned == identifier else { return }
      switch await persist(identifier) {
      case .kept, .rejected:
        return
      case .retry:
        continue
      }
    }
    guard assigned == identifier, captured == nil else { return }
    unstored = identifier
  }

  private func persist(_ identifier: String) async -> Persistence {
    let outcome: RecordAgentResumeIdentifierOutcome
    do {
      outcome = try await record(sessionID: sessionID, identifier: identifier)
    } catch {
      return .retry
    }
    guard assigned == identifier else { return .rejected }

    if outcome.isPersisted {
      captured = identifier
      unstored = nil
      return .kept
    }
    return outcome.isRetryable ? .retry : .rejected
  }

  private enum Persistence {
    case kept
    case retry
    case rejected
  }
}
