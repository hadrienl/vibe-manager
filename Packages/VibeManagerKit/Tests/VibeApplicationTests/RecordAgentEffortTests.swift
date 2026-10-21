import Foundation
import Testing
import VibeApplication
import VibeDomain

@Suite("Recording the effort given to an agent (#411)")
struct RecordAgentEffortTests {
  private func session(providerID: String = "codex", effort: String? = nil) -> WorkSession {
    WorkSession(
      name: "Effort",
      agent: SessionAgentConfiguration(providerID: providerID, modelID: "gpt-6", effort: effort))
  }

  @Test("The level is written on the session's agent, and nil puts back its default")
  func records() async throws {
    let stored = session()
    let repository = RestorationRepository(sessions: [stored])
    let record = RecordAgentEffort(repository: repository)

    try await record(sessionID: stored.id, providerID: "codex", effort: "high")
    #expect(await repository.session(id: stored.id)?.agent?.effort == "high")

    try await record(sessionID: stored.id, providerID: "codex", effort: nil)
    #expect(await repository.session(id: stored.id)?.agent?.effort == nil)
  }

  @Test("Nothing is written on a session handed to another agent, nor a malformed level")
  func refuses() async throws {
    let stored = session(providerID: "claude-code", effort: "low")
    let repository = RestorationRepository(sessions: [stored])
    let record = RecordAgentEffort(repository: repository)

    try await record(sessionID: stored.id, providerID: "codex", effort: "high")
    #expect(await repository.session(id: stored.id)?.agent?.effort == "low")

    try await record(sessionID: stored.id, providerID: "claude-code", effort: "-c x=1")
    #expect(await repository.session(id: stored.id)?.agent?.effort == nil)
  }
}
