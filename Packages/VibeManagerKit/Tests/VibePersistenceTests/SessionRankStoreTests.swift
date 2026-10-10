import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("Keeping the order arranged by hand in the store")
struct SessionRankStoreTests {
  private func temporaryStore() throws -> (FileSessionRepository, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SessionRankStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("sessions.json")
    return (FileSessionRepository(storeURL: url), directory)
  }

  private func session(_ name: String, updatedAt seconds: TimeInterval, rank: Int = 0)
    -> WorkSession
  {
    WorkSession(
      name: name, createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: seconds), rank: rank)
  }

  @Test("A v7 store is ranked last activity first, and rewritten in v8")
  func v7IsMigrated() throws {
    let codec = SessionStoreCodec()
    let sessions = [
      session("Old", updatedAt: 100), session("New", updatedAt: 300),
      session("Middle", updatedAt: 200),
    ]
    let v7 = String(decoding: try codec.encode(sessions: sessions), as: UTF8.self)
      .replacingOccurrences(of: #""schemaVersion" : 10"#, with: #""schemaVersion" : 7"#)

    let decoded = try codec.decode(Data(v7.utf8))

    #expect(decoded.requiresRewrite)
    #expect(SessionOrder.ordered(decoded.sessions).map(\.name) == ["New", "Middle", "Old"])
    #expect(Set(decoded.sessions.map(\.rank)) == [0, 1, 2])
  }

  @Test("A v8 store keeps its ranks as written")
  func v8RoundTrip() throws {
    let codec = SessionStoreCodec()
    let sessions = [session("A", updatedAt: 100, rank: 5), session("B", updatedAt: 300, rank: -2)]

    let decoded = try codec.decode(try codec.encode(sessions: sessions))

    #expect(!decoded.requiresRewrite)
    #expect(decoded.sessions.map(\.rank) == [5, -2])
  }

  @Test("A new session enters at the top; a known one keeps its place when saved again")
  func newSessionsOnTop() async throws {
    let (repository, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = session("First", updatedAt: 100)
    try await repository.save(first)
    try await repository.save(session("Second", updatedAt: 50))
    var renamed = first
    renamed.name = "First, renamed"
    renamed.rank = 99
    try await repository.save(renamed)

    let stored = try await repository.sessions()
    #expect(SessionOrder.ordered(stored).map(\.name) == ["Second", "First, renamed"])
  }

  @Test("Reordering writes the ranks in one go, without touching the last activity")
  func reorder() async throws {
    let (repository, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = session("A", updatedAt: 100)
    let b = session("B", updatedAt: 200)
    try await repository.save(a)
    try await repository.save(b)

    try await repository.reorder([a.id: -10, SessionID(): 3])

    let stored = try await repository.sessions()
    #expect(SessionOrder.ordered(stored).map(\.name) == ["A", "B"])
    #expect(stored.first { $0.id == a.id }?.updatedAt == a.updatedAt)
    #expect(stored.count == 2)
  }

  @Test("A status change, a close and an archive keep a session's place")
  func lifecycleKeepsTheRank() async throws {
    let repository = InMemorySessionRepository(sessions: [
      WorkSession(
        name: "Running", status: .active, createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 10), startedAt: Date(timeIntervalSince1970: 0),
        rank: 7)
    ])
    let id = try #require(await repository.sessions().first?.id)

    _ = try await ChangeTaskStatus(repository: repository)(id: id, to: .waiting)
    _ = try await CloseSession(repository: repository)(id: id)
    _ = try await ArchiveSession(repository: repository)(id: id)
    _ = try await RestoreSession(repository: repository)(id: id)

    #expect(await repository.session(id: id)?.rank == 7)
  }
}
