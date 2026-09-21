import VibeDomain

public struct LoadSessions: Sendable {
  private let repository: any SessionRepository

  public init(repository: any SessionRepository) {
    self.repository = repository
  }

  public func callAsFunction() async throws -> [WorkSession] {
    try await repository.sessions().sorted { lhs, rhs in
      if lhs.updatedAt == rhs.updatedAt {
        return lhs.id.description < rhs.id.description
      }
      return lhs.updatedAt > rhs.updatedAt
    }
  }
}
