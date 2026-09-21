import Foundation
import Testing

@testable import VibeDomain

@Test("A work session can round-trip through Codable")
func workSessionCodableRoundTrip() throws {
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  let identifier = try #require(UUID(uuidString: "88E8C16B-2824-4CCC-8EF4-C7A1C16EA3AD"))
  let session = WorkSession(
    id: SessionID(rawValue: identifier),
    name: "Bootstrap the app",
    status: .active,
    createdAt: date,
    updatedAt: date
  )

  let data = try JSONEncoder().encode(session)
  let decoded = try JSONDecoder().decode(WorkSession.self, from: data)

  #expect(decoded == session)
}

@Test("A session follows the reversible lifecycle")
func sessionLifecycleTransitions() throws {
  let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
  var session = WorkSession(
    name: "Lifecycle",
    status: .active,
    createdAt: createdAt,
    updatedAt: createdAt
  )

  try session.close(at: createdAt.addingTimeInterval(10))
  #expect(session.status == .closed)
  #expect(session.closedAt == createdAt.addingTimeInterval(10))

  try session.archive(at: createdAt.addingTimeInterval(20))
  #expect(session.status == .archived)
  #expect(session.archivedAt == createdAt.addingTimeInterval(20))

  try session.restore(at: createdAt.addingTimeInterval(30))
  #expect(session.status == .closed)
  #expect(session.closedAt == createdAt.addingTimeInterval(10))
  #expect(session.archivedAt == nil)

  try session.reopen(at: createdAt.addingTimeInterval(40))
  #expect(session.status == .active)
  #expect(session.closedAt == nil)
}

@Test("Invalid lifecycle transitions leave the session unchanged")
func invalidLifecycleTransition() {
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  var session = WorkSession(
    name: "Active",
    status: .active,
    createdAt: date,
    updatedAt: date
  )

  #expect(throws: SessionTransitionError.invalidTransition(from: .active, to: .archived)) {
    try session.archive(at: date.addingTimeInterval(1))
  }
  #expect(session.status == .active)
  #expect(session.updatedAt == date)
}

@Test("Archiving a legacy closed session fills its missing closure date")
func archiveLegacyClosedSession() throws {
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  var session = WorkSession(
    name: "Legacy closed",
    status: .closed,
    createdAt: date,
    updatedAt: date
  )

  try session.archive(at: date.addingTimeInterval(10))

  #expect(session.status == .archived)
  #expect(session.closedAt == date)
  try session.validate()
}

@Test("A complete session validates its bounded metadata")
func completeSessionValidation() throws {
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  let session = WorkSession(
    name: "Implement persistence",
    initialPrompt: "Implement ticket #2",
    agent: SessionAgentConfiguration(
      providerID: "codex",
      modelID: "gpt-5",
      resumeIdentifier: "thread-123"
    ),
    appearance: SessionAppearance(symbolName: "externaldrive", colorHex: "#FF9500"),
    status: .active,
    createdAt: date,
    updatedAt: date,
    repositories: [
      RepositoryContext(
        path: "/projects/vibe-manager",
        git: GitSnapshot(
          repositoryRootPath: "/projects/vibe-manager",
          branchName: "feature/persistence",
          headRevision: "abc123",
          isDirty: true,
          capturedAt: date
        )
      )
    ],
    notes: "Keep the store local",
    template: PromptTemplateReference(id: "implementation", name: "Implementation", revision: "2")
  )

  try session.validate()
}
