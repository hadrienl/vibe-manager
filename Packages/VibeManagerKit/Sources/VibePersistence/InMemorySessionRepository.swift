import VibeApplication
import VibeDomain

public actor InMemorySessionRepository: SessionRepository {
  private var storage: [SessionID: WorkSession]

  public init(sessions: [WorkSession] = []) {
    storage = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
  }

  public func sessions() -> [WorkSession] {
    storage.values.sorted { lhs, rhs in
      if lhs.updatedAt == rhs.updatedAt {
        return lhs.id.description < rhs.id.description
      }
      return lhs.updatedAt > rhs.updatedAt
    }
  }

  public func session(id: SessionID) -> WorkSession? {
    storage[id]
  }

  /// A new session enters at the top, and a known one keeps its place, as in the file store.
  public func save(_ session: WorkSession) {
    var saved = session
    saved.rank = storage[session.id]?.rank ?? ((storage.values.map(\.rank).min() ?? 1) - 1)
    storage[session.id] = saved
  }

  public func reorder(_ ranks: [SessionID: Int]) {
    for (id, rank) in ranks where storage[id] != nil {
      storage[id]?.rank = rank
    }
  }

  public func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) async throws -> WorkSession? {
    guard var session = storage[id] else { return nil }
    try transform(&session)
    storage[id] = session
    return session
  }
}
