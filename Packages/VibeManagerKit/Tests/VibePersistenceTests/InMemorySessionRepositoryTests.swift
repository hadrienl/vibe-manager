import Testing
import VibeDomain

@testable import VibePersistence

@Test("Saving a session replaces the value with the same identifier")
func saveReplacesExistingSession() async throws {
  var session = WorkSession(name: "Initial")
  let repository = InMemorySessionRepository(sessions: [session])

  session.name = "Updated"
  await repository.save(session)
  let sessions = await repository.sessions()

  #expect(sessions.count == 1)
  #expect(sessions.first?.name == "Updated")
}
