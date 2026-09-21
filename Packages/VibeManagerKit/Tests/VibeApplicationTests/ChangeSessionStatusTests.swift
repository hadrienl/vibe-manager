import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private actor StatusSessionRepository: SessionRepository {
  private var value: WorkSession

  init(value: WorkSession) {
    self.value = value
  }

  func sessions() -> [WorkSession] {
    [value]
  }

  func session(id: SessionID) -> WorkSession? {
    value.id == id ? value : nil
  }

  func save(_ session: WorkSession) {
    value = session
  }
}

private struct FixedSessionClock: SessionClock {
  let value: Date

  func now() -> Date {
    value
  }
}

@Test("The lifecycle use case timestamps and persists a transition")
func lifecycleUseCasePersistsTransition() async throws {
  let createdAt = Date(timeIntervalSince1970: 100)
  let closedAt = Date(timeIntervalSince1970: 200)
  let session = WorkSession(
    name: "Running",
    status: .active,
    createdAt: createdAt,
    updatedAt: createdAt
  )
  let repository = StatusSessionRepository(value: session)
  let changeStatus = ChangeSessionStatus(
    repository: repository,
    clock: FixedSessionClock(value: closedAt)
  )

  let updated = try await changeStatus(id: session.id, action: .close)

  #expect(updated.status == .closed)
  #expect(updated.closedAt == closedAt)
  #expect(await repository.session(id: session.id) == updated)
}
