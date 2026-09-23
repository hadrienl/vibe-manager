import Foundation
import VibeDomain

/// Why a resume identifier was, or was not, written on a session.
///
/// A plain `false` conflated "nothing to do" with "the session is not ready yet". The caller
/// needs to tell them apart: the second one is worth retrying, and losing it silently makes a
/// session unresumable for good.
public enum RecordAgentResumeIdentifierOutcome: Sendable, Equatable {
  /// The identifier was written.
  case recorded
  /// The session already carried exactly this identifier.
  case unchanged
  /// No session with this identifier exists — it may not have been persisted yet.
  case sessionMissing
  /// The session exists but carries no agent configuration yet.
  case agentMissing
  /// The identifier is blank: no write can ever succeed.
  case rejected
  /// The session has been switched to another agent since this one was launched. Its identifier
  /// names a conversation of the previous agent, and written on the next one it would have that
  /// agent asked to resume something it has never heard of.
  case agentChanged

  /// Whether the session now carries the identifier.
  public var isPersisted: Bool {
    self == .recorded || self == .unchanged
  }

  /// Whether the same call could succeed later, once the session is fully written.
  public var isRetryable: Bool {
    self == .sessionMissing || self == .agentMissing
  }
}

public struct RecordAgentResumeIdentifier: Sendable {
  private let repository: any SessionRepository
  private let providerID: String?
  private let launchedAt: Date?

  /// - Parameters:
  ///   - providerID: the agent whose launch revealed the identifier. When given, nothing is written
  ///     on a session whose agent is no longer that one.
  ///   - launchedAt: when that launch started. When given, nothing is written on a session that was
  ///     switched since — to another agent, or to another model of the same one, whose conversation
  ///     this identifier does not name either.
  public init(
    repository: any SessionRepository,
    providerID: String? = nil,
    launchedAt: Date? = nil
  ) {
    self.repository = repository
    self.providerID = providerID
    self.launchedAt = launchedAt
  }

  /// Whether the session's agent is still the one this launch started.
  private func isStillLaunched(on session: WorkSession) -> Bool {
    if let providerID, session.agent?.providerID != providerID { return false }
    if let launchedAt,
      session.agentHistory.contains(where: { $0.outcome == .completed && $0.date > launchedAt })
    {
      return false
    }
    return true
  }

  @discardableResult
  public func callAsFunction(
    sessionID: SessionID,
    identifier: String
  ) async throws -> RecordAgentResumeIdentifierOutcome {
    let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { return .rejected }

    guard let current = try await repository.session(id: sessionID) else { return .sessionMissing }
    guard let agent = current.agent else { return .agentMissing }
    guard isStillLaunched(on: current) else { return .agentChanged }
    guard agent.resumeIdentifier != identifier else { return .unchanged }

    let updated = try await repository.mutate(id: sessionID) { [self] session in
      guard var agent = session.agent, agent.resumeIdentifier != identifier else { return }
      // Decided again on the copy the write is made on: a switch may have landed in between.
      guard isStillLaunched(on: session) else { return }
      agent.resumeIdentifier = identifier
      session.agent = agent
    }
    guard let updated else { return .sessionMissing }
    guard isStillLaunched(on: updated) else { return .agentChanged }
    guard updated.agent?.resumeIdentifier == identifier else { return .agentMissing }
    return .recorded
  }
}
