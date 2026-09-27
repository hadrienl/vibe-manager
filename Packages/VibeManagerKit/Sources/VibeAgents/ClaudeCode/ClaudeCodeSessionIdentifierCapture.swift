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
///
/// The CLI creates that transcript with the first message, not at launch (checked with 2.1.283):
/// a session started without a prompt has none for as long as the user takes to write to it. So
/// the watch lasts as long as the process does (#138) — bounded all the same by a limit of hours,
/// so that a launch whose end is never reported cannot keep looking at the disk for good.
public actor ClaudeCodeSessionIdentifierCapture {
  public static let defaultPersistenceWindow: Duration = .seconds(10)
  /// How long the transcript is waited for at most. The process ending stops the watch well
  /// before, as a rule: this is only the safety net, set for a working day.
  public static let defaultTranscriptWatchLimit: Duration = .seconds(12 * 3600)
  static let retryInterval: Duration = .milliseconds(200)

  private let sessionID: SessionID
  private let record: RecordAgentResumeIdentifier
  private let transcripts: any ClaudeCodeTranscriptWatching
  private let transcriptWatchLimit: Duration
  private let persistenceWindow: Duration

  private var assigned: String?
  private var captured: String?
  private var unstored: String?
  private var watcher: Task<Void, Never>?
  private var persister: Task<Void, Never>?
  /// The last look of `finish`, awaited by every call that follows the first.
  private var finishing: Task<Void, Never>?
  /// Calls to `finish` so far, for the tests.
  private(set) var finishRequests = 0

  public init(
    sessionID: SessionID,
    record: RecordAgentResumeIdentifier,
    transcripts: any ClaudeCodeTranscriptWatching = ClaudeCodeTranscriptWatcher(),
    transcriptWatchLimit: Duration =
      ClaudeCodeSessionIdentifierCapture.defaultTranscriptWatchLimit,
    persistenceWindow: Duration = ClaudeCodeSessionIdentifierCapture.defaultPersistenceWindow
  ) {
    self.sessionID = sessionID
    self.record = record
    self.transcripts = transcripts
    self.transcriptWatchLimit = transcriptWatchLimit
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
    finishing = nil
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

  /// The process ended: the watch stops, after one last look. A first message sent just before
  /// the agent quit leaves a transcript the watch has not seen yet, and it is a conversation to
  /// resume all the same.
  ///
  /// The end is reported more than once — the terminal's output ends, then the launcher lets go
  /// of the session — and every call returns only once that last look is over: none of them
  /// may return while the identifier is still being written.
  public func finish() async {
    finishRequests += 1
    if let finishing {
      await finishing.value
      return
    }
    let wasWatching = watcher != nil
    stop()
    guard wasWatching, let identifier = assigned, captured == nil else { return }
    let last = Task<Void, Never> { [weak self] in await self?.lookOnceMore(for: identifier) }
    finishing = last
    await last.value
  }

  private func lookOnceMore(for identifier: String) async {
    guard await transcripts.awaitTranscript(identifier: identifier, timeout: .zero) else { return }
    guard assigned == identifier, captured == nil else { return }
    _ = await persist(identifier)
  }

  /// Waits for the conversation to exist, then writes its identifier down.
  ///
  /// The wait ends with the process (`stop`, `finish`), or at the latest after the watch limit: a
  /// conversation that never appears is one there is nothing to resume, so the identifier is
  /// dropped rather than surfaced — unlike a write that failed, nothing was lost.
  private func storeOnceWritten(_ identifier: String) async {
    let exists = await transcripts.awaitTranscript(
      identifier: identifier,
      timeout: transcriptWatchLimit
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
