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

  /// - Parameter providerID: the agent whose launch revealed the identifier. When given, nothing is
  ///   written on a session whose agent is no longer that one.
  public init(repository: any SessionRepository, providerID: String? = nil) {
    self.repository = repository
    self.providerID = providerID
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
    if let providerID, agent.providerID != providerID { return .agentChanged }
    guard agent.resumeIdentifier != identifier else { return .unchanged }

    let providerID = providerID
    let updated = try await repository.mutate(id: sessionID) { session in
      guard var agent = session.agent, agent.resumeIdentifier != identifier else { return }
      // Decided again on the copy the write is made on: a switch may have landed in between.
      if let providerID, agent.providerID != providerID { return }
      agent.resumeIdentifier = identifier
      session.agent = agent
    }
    guard let updated else { return .sessionMissing }
    if let providerID, updated.agent?.providerID != providerID { return .agentChanged }
    guard updated.agent?.resumeIdentifier == identifier else { return .agentMissing }
    return .recorded
  }
}
