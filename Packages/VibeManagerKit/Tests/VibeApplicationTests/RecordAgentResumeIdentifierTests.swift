import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

/// An atomic repository, like the file backed one: the read, the change and the write happen
/// inside the actor, so a concurrent caller cannot overwrite another's change.
private actor RecordingRepository: SessionRepository {
  private var stored: WorkSession?
  private(set) var saveCount = 0

  init(stored: WorkSession?) {
    self.stored = stored
  }

  func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) throws -> WorkSession? {
    guard var session = stored, session.id == id else { return nil }
    let before = session
    try transform(&session)
    guard session != before else { return session }
    stored = session
    saveCount += 1
    return session
  }

  func sessions() -> [WorkSession] {
    stored.map { [$0] } ?? []
  }

  func session(id: SessionID) -> WorkSession? {
    stored?.id == id ? stored : nil
  }

  func save(_ session: WorkSession) {
    stored = session
    saveCount += 1
  }
}

private func session(resumeIdentifier: String? = nil, hasAgent: Bool = true) -> WorkSession {
  WorkSession(
    name: "Refonte du parseur",
    agent: hasAgent
      ? SessionAgentConfiguration(
        providerID: "codex",
        modelID: "gpt-6-astra",
        resumeIdentifier: resumeIdentifier
      )
      : nil
  )
}

@Test("The identifier is stored on the session agent configuration")
func storesIdentifier() async throws {
  let stored = session()
  let repository = RecordingRepository(stored: stored)

  let changed = try await RecordAgentResumeIdentifier(repository: repository)(
    sessionID: stored.id,
    identifier: "019ee0a1-06d9-7e52-957b-d61a982d6b43"
  )

  #expect(changed)
  let saved = await repository.session(id: stored.id)
  #expect(saved?.agent?.resumeIdentifier == "019ee0a1-06d9-7e52-957b-d61a982d6b43")
}

@Test("Recording the same identifier again writes nothing")
func idempotentWrite() async throws {
  let identifier = "019ee0a1-06d9-7e52-957b-d61a982d6b43"
  let stored = session(resumeIdentifier: identifier)
  let repository = RecordingRepository(stored: stored)
  let record = RecordAgentResumeIdentifier(repository: repository)

  #expect(try await record(sessionID: stored.id, identifier: identifier) == false)
  #expect(await repository.saveCount == 0)
}

@Test("A blank identifier is ignored")
func ignoresBlankIdentifier() async throws {
  let stored = session()
  let repository = RecordingRepository(stored: stored)

  #expect(
    try await RecordAgentResumeIdentifier(repository: repository)(
      sessionID: stored.id,
      identifier: "  \n "
    ) == false)
  #expect(await repository.saveCount == 0)
}

@Test("A session without an agent gains no identifier")
func ignoresSessionWithoutAgent() async throws {
  let stored = session(hasAgent: false)
  let repository = RecordingRepository(stored: stored)

  #expect(
    try await RecordAgentResumeIdentifier(repository: repository)(
      sessionID: stored.id,
      identifier: "019ee0a1-06d9-7e52-957b-d61a982d6b43"
    ) == false)
  #expect(await repository.saveCount == 0)
}

@Test("An unknown session is not created by a resume identifier")
func ignoresUnknownSession() async throws {
  let repository = RecordingRepository(stored: nil)

  #expect(
    try await RecordAgentResumeIdentifier(repository: repository)(
      sessionID: SessionID(),
      identifier: "019ee0a1-06d9-7e52-957b-d61a982d6b43"
    ) == false)
  #expect(await repository.saveCount == 0)
}

@Test("An identifier replaces the one of a previous run")
func replacesPreviousIdentifier() async throws {
  let stored = session(resumeIdentifier: "019ee0a1-0000-7e52-957b-d61a982d6b43")
  let repository = RecordingRepository(stored: stored)

  let changed = try await RecordAgentResumeIdentifier(repository: repository)(
    sessionID: stored.id,
    identifier: "019ee0a1-06d9-7e52-957b-d61a982d6b43"
  )

  #expect(changed)
  let saved = await repository.session(id: stored.id)
  #expect(saved?.agent?.resumeIdentifier == "019ee0a1-06d9-7e52-957b-d61a982d6b43")
}

@Test("A rename made at the same time as the identifier is not lost")
func concurrentChangeIsPreserved() async throws {
  let stored = session()
  let repository = RecordingRepository(stored: stored)
  let identifier = "019ee0a1-06d9-7e52-957b-d61a982d6b43"

  async let recorded: Bool = RecordAgentResumeIdentifier(repository: repository)(
    sessionID: stored.id,
    identifier: identifier
  )
  async let renamed: WorkSession? = repository.mutate(id: stored.id) { session in
    session.name = "Nouveau nom"
  }

  _ = try await (recorded, renamed)
  let saved = await repository.session(id: stored.id)
  // Both changes went through the same atomic step, so neither erased the other.
  #expect(saved?.agent?.resumeIdentifier == identifier)
  #expect(saved?.name == "Nouveau nom")
}
