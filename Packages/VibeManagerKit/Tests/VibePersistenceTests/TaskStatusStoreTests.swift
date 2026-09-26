import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("Keeping each session's task status in the store")
struct TaskStatusStoreTests {
  /// One v4 session, its lifecycle given as JSON.
  private func v4Document(lifecycle: String, extra: String = "") -> String {
    """
    {
      "schemaVersion": 4,
      "savedAt": "2026-09-21T10:00:00.000Z",
      "sessions": [
        {
          "id": "88E8C16B-2824-4CCC-8EF4-C7A1C16EA3AD",
          "name": "Stored in v4",
          "initialPrompt": "Do it",
          "agent": { "providerID": "codex" },
          "appearance": { "symbolName": "terminal", "colorHex": "#5E5CE6" },
          "lifecycle": \(lifecycle),
          "repositories": []\(extra)
        }
      ]
    }
    """
  }

  private let running = """
    { "status": "active", "createdAt": "2026-09-21T09:00:00.000Z",
      "updatedAt": "2026-09-21T10:00:00.000Z", "startedAt": "2026-09-21T09:00:00.000Z" }
    """
  private let neverStarted = """
    { "status": "closed", "createdAt": "2026-09-21T09:00:00.000Z",
      "updatedAt": "2026-09-21T09:00:00.000Z", "closedAt": "2026-09-21T09:00:00.000Z" }
    """
  private let stopped = """
    { "status": "closed", "createdAt": "2026-09-21T09:00:00.000Z",
      "updatedAt": "2026-09-21T10:00:00.000Z", "closedAt": "2026-09-21T10:00:00.000Z",
      "startedAt": "2026-09-21T09:00:00.000Z" }
    """
  private let archived = """
    { "status": "archived", "createdAt": "2026-09-21T09:00:00.000Z",
      "updatedAt": "2026-09-21T11:00:00.000Z", "closedAt": "2026-09-21T10:00:00.000Z",
      "archivedAt": "2026-09-21T11:00:00.000Z", "startedAt": "2026-09-21T09:00:00.000Z" }
    """

  private func decodedStatus(_ document: String) throws -> SessionTaskStatus? {
    try SessionStoreCodec().decode(Data(document.utf8)).sessions.first?.taskStatus
  }

  @Test("A v4 session gets the status its lifecycle says, and the store is rewritten")
  func v4IsMigrated() throws {
    #expect(try decodedStatus(v4Document(lifecycle: running)) == .doing)
    #expect(try decodedStatus(v4Document(lifecycle: neverStarted)) == .todo)
    #expect(try decodedStatus(v4Document(lifecycle: stopped)) == .done)
    #expect(try decodedStatus(v4Document(lifecycle: archived)) == .archived)
    #expect(
      try SessionStoreCodec().decode(Data(v4Document(lifecycle: stopped).utf8)).requiresRewrite)
  }

  @Test("A v5 session keeps its ticket, gets the status its lifecycle says, and is rewritten")
  func v5IsMigrated() throws {
    let document = v4Document(
      lifecycle: running,
      extra: #", "ticket": { "url": "https://github.com/o/r/issues/1", "source": "manual" }"#
    ).replacingOccurrences(of: "\"schemaVersion\": 4", with: "\"schemaVersion\": 5")

    let decoded = try SessionStoreCodec().decode(Data(document.utf8))

    let session = try #require(decoded.sessions.first)
    #expect(session.taskStatus == .doing)
    #expect(session.ticket?.url == URL(string: "https://github.com/o/r/issues/1"))
    #expect(decoded.requiresRewrite)
  }

  @Test("A status comes back as it was written")
  func statusRoundTrips() throws {
    var session = WorkSession(
      name: "Waiting on review", status: .active, createdAt: Date(timeIntervalSince1970: 100),
      updatedAt: Date(timeIntervalSince1970: 100), startedAt: Date(timeIntervalSince1970: 100))
    try session.setTaskStatus(.waiting, at: Date(timeIntervalSince1970: 200))
    let codec = SessionStoreCodec()

    let data = try codec.encode(sessions: [session])
    let decoded = try codec.decode(data)

    #expect(decoded.sessions == [session])
    #expect(decoded.requiresRewrite == false)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 6)
  }

  @Test("A status written by a later build is read from the lifecycle")
  func unknownStatusFallsBack() throws {
    let document = v4Document(lifecycle: running, extra: #", "taskStatus": "blocked""#)
      .replacingOccurrences(of: "\"schemaVersion\": 4", with: "\"schemaVersion\": 6")
    #expect(try decodedStatus(document) == .doing)
  }

  /// Archived is the one status the lifecycle decides. A document where the two disagree would
  /// otherwise fail validation, and the whole store with it.
  @Test("A status that contradicts the lifecycle is dropped rather than taking the store down")
  func contradictoryStatusIsDropped() throws {
    let archivedAsTask = v4Document(lifecycle: stopped, extra: #", "taskStatus": "archived""#)
      .replacingOccurrences(of: "\"schemaVersion\": 4", with: "\"schemaVersion\": 6")
    let archivedAsProcess = v4Document(lifecycle: archived, extra: #", "taskStatus": "waiting""#)
      .replacingOccurrences(of: "\"schemaVersion\": 4", with: "\"schemaVersion\": 6")

    #expect(try decodedStatus(archivedAsTask) == .done)
    #expect(try decodedStatus(archivedAsProcess) == .archived)
  }

  /// Moving a session touches it. Read back from a store that inferred the start from the dates,
  /// a session that never ran would come back as one that did, and moving it In Progress would
  /// restart it instead of starting it with its prompt.
  @Test("A session that never ran is still one after it moved, read back from the file")
  func neverStartedSurvivesAMove() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeManagerTaskStatus-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = FileSessionRepository(
      storeURL: directory.appendingPathComponent("sessions.json"))
    let planned = SessionDraft(
      name: "Planned", initialPrompt: "Later.", providerID: "codex",
      workingDirectoryPath: directory.path
    ).session(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    try await repository.save(planned)

    let change = ChangeTaskStatus(repository: repository)
    try await change(id: planned.id, to: .waiting)
    try await change(id: planned.id, to: .todo)

    let stored = try #require(try await repository.session(id: planned.id))
    #expect(stored.taskStatus == .todo)
    #expect(!stored.hasEverStarted)
    #expect(stored.updatedAt > stored.createdAt)
  }
}
