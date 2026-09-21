import Foundation
import VibeDomain

/// Stores the identifier an agent exposes so its session can be resumed later.
///
/// The write goes through `SessionRepository.mutate`, so a concurrent change to the same
/// session — a rename, a status change — is not lost. Only the identifier is persisted:
/// ADR 0002 keeps transcripts out of the session store, and this use case does not widen it.
public struct RecordAgentResumeIdentifier: Sendable {
  private let repository: any SessionRepository

  public init(repository: any SessionRepository) {
    self.repository = repository
  }

  /// - Returns: `true` when the stored identifier changed.
  @discardableResult
  public func callAsFunction(sessionID: SessionID, identifier: String) async throws -> Bool {
    let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { return false }

    // Agents report their identifier repeatedly while they run. Reading first keeps the
    // steady state free of writes, instead of rewriting the session document every time.
    guard let current = try await repository.session(id: sessionID) else { return false }
    guard let agent = current.agent else { return false }
    guard agent.resumeIdentifier != identifier else { return false }

    let updated = try await repository.mutate(id: sessionID) { session in
      // Re-checked inside the transaction: the session may have gained an identifier, or
      // lost its agent, between the read above and this write.
      guard var agent = session.agent, agent.resumeIdentifier != identifier else { return }
      agent.resumeIdentifier = identifier
      session.agent = agent
    }
    return updated?.agent?.resumeIdentifier == identifier
  }
}
