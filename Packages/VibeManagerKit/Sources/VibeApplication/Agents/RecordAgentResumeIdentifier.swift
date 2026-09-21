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

  public init(repository: any SessionRepository) {
    self.repository = repository
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
    guard agent.resumeIdentifier != identifier else { return .unchanged }

    let updated = try await repository.mutate(id: sessionID) { session in
      guard var agent = session.agent, agent.resumeIdentifier != identifier else { return }
      agent.resumeIdentifier = identifier
      session.agent = agent
    }
    guard let updated else { return .sessionMissing }
    guard updated.agent?.resumeIdentifier == identifier else { return .agentMissing }
    return .recorded
  }
}
