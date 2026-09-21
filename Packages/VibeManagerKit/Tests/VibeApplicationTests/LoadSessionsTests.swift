import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private actor FakeSessionRepository: SessionRepository {
  private var values: [WorkSession]

  init(values: [WorkSession]) {
    self.values = values
  }

  func sessions() -> [WorkSession] {
    values
  }

  func save(_ session: WorkSession) {
    values.append(session)
  }
}

@Test("Sessions are ordered by most recent update")
func sessionsAreOrderedByMostRecentUpdate() async throws {
  let older = WorkSession(
    name: "Older",
    updatedAt: Date(timeIntervalSince1970: 100)
  )
  let newer = WorkSession(
    name: "Newer",
    updatedAt: Date(timeIntervalSince1970: 200)
  )
  let repository = FakeSessionRepository(values: [older, newer])

  let sessions = try await LoadSessions(repository: repository)()

  #expect(sessions.map(\.name) == ["Newer", "Older"])
}
