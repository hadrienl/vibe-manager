import Foundation
import VibeDomain

/// Writes on a session the reasoning effort its agent was just given (#411), for the launches
/// that follow — a restart, a resume, a switch to another model of the same agent.
public struct RecordAgentEffort: Sendable {
  private let repository: any SessionRepository

  public init(repository: any SessionRepository) {
    self.repository = repository
  }

  /// - Parameters:
  ///   - providerID: the agent the level was given to. Nothing is written on a session handed to
  ///     another one meanwhile, whose levels are not the same.
  ///   - effort: the level, `nil` for the agent's own default.
  /// - Returns: the session as written, `nil` when nothing was.
  @discardableResult
  public func callAsFunction(
    sessionID: SessionID, providerID: String, effort: String?
  ) async throws -> WorkSession? {
    let effort = effort.flatMap(AgentEffortLevel.argument)
    return try await repository.mutate(id: sessionID) { session in
      guard var agent = session.agent, agent.providerID == providerID, agent.effort != effort
      else { return }
      agent.effort = effort
      session.agent = agent
    }
  }
}
