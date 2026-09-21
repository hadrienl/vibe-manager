import VibeApplication
import VibeDomain

public actor InMemorySessionRepository: SessionRepository {
  private var storage: [SessionID: WorkSession]

  public init(sessions: [WorkSession] = []) {
    storage = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
  }

  public func sessions() -> [WorkSession] {
    Array(storage.values)
  }

  public func save(_ session: WorkSession) {
    storage[session.id] = session
  }
}
