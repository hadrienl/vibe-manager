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

  public func save(_ session: WorkSession) {
    storage[session.id] = session
  }
}
