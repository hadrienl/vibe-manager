import Foundation
import VibeApplication
import VibeDomain

/// Keeps the identifier a launch plan assigned to a Claude Code conversation.
///
/// There is nothing to discover: the plan already names the conversation, so the only work left
/// is to store that name on the work session. That store can still fail — the session row may
/// not exist yet, or may not carry its agent configuration when the pane starts — so it is
/// retried inside a bounded window, and what it never managed to write is exposed rather than
/// dropped.
public actor ClaudeCodeSessionIdentifierCapture {
  public static let defaultPersistenceWindow: Duration = .seconds(10)
  static let retryInterval: Duration = .milliseconds(200)

  private let sessionID: SessionID
  private let record: RecordAgentResumeIdentifier
  private let persistenceWindow: Duration

  private var assigned: String?
  private var captured: String?
  private var unstored: String?
  private var persister: Task<Void, Never>?

  public init(
    sessionID: SessionID,
    record: RecordAgentResumeIdentifier,
    persistenceWindow: Duration = ClaudeCodeSessionIdentifierCapture.defaultPersistenceWindow
  ) {
    self.sessionID = sessionID
    self.record = record
    self.persistenceWindow = persistenceWindow
  }

  /// The identifier the launched process was started with, stored or not.
  public var assignedIdentifier: String? {
    assigned
  }

  /// The identifier the session actually carries.
  public var identifier: String? {
    captured
  }

  /// Assigned, but never written to the session: the conversation exists and this application
  /// can no longer point at it. Worth surfacing, never worth pretending away.
  public var unstoredIdentifier: String? {
    unstored
  }

  /// Records the identifier the plan carries. A resume plan carries none — it reuses the one
  /// already stored — so it changes nothing.
  @discardableResult
  public func record(plan: AgentLaunchPlan) async -> String? {
    guard let identifier = ClaudeCodeArgumentBuilder.assignedSessionIdentifier(in: plan.arguments)
    else {
      return nil
    }

    // A new launch of the same work session is a new conversation, and replaces the previous
    // identifier on purpose.
    persister?.cancel()
    persister = nil
    assigned = identifier
    captured = nil
    unstored = nil

    switch await persist(identifier) {
    case .kept, .rejected:
      break
    case .retry:
      persister = Task { [weak self] in await self?.keepTrying(identifier) }
    }
    return identifier
  }

  /// Waits for a pending write to settle and returns what the session carries.
  public func settled() async -> String? {
    await persister?.value
    return captured
  }

  public func stop() {
    persister?.cancel()
    persister = nil
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
