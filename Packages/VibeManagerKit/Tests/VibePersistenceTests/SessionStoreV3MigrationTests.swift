import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("Migrating a schema v2 store to v3")
struct SessionStoreV3MigrationTests {
  private func makeStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeManagerV3-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("sessions.json")
  }

  /// Two folders that do not exist: a migration that looked at the disk would fail on them, or
  /// worse, create something there.
  private let v2Document = """
    {
      "schemaVersion": 2,
      "savedAt": "2026-09-21T10:00:00.000Z",
      "sessions": [
        {
          "id": "88E8C16B-2824-4CCC-8EF4-C7A1C16EA3AD",
          "name": "Stored before worktrees",
          "initialPrompt": "",
          "agent": { "providerID": "codex", "modelID": null, "resumeIdentifier": "thread-9" },
          "appearance": { "symbolName": "terminal", "colorHex": "#5E5CE6" },
          "lifecycle": {
            "status": "closed",
            "createdAt": "2026-09-21T09:00:00.000Z",
            "updatedAt": "2026-09-21T10:00:00.000Z",
            "closedAt": "2026-09-21T10:00:00.000Z",
            "startedAt": "2026-09-21T09:00:00.000Z"
          },
          "repositories": [
            { "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "path": "/nowhere/vibe-v2/api" },
            { "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3302", "path": "/nowhere/vibe-v2/web" }
          ]
        }
      ]
    }
    """

  @Test("Every v2 folder becomes a repository attached in place, and nothing else is invented")
  func v2FoldersBecomeInPlace() async throws {
    let storeURL = try makeStoreURL()
    defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
    try Data(v2Document.utf8).write(to: storeURL)

    let session = try #require(try await FileSessionRepository(storeURL: storeURL).sessions().first)

    #expect(
      session.repositories.map(\.rootPath) == ["/nowhere/vibe-v2/api", "/nowhere/vibe-v2/web"])
    #expect(session.repositories.allSatisfy { $0.mode == .inPlace })
    #expect(session.repositories.allSatisfy { $0.worktreePath == nil && $0.branchName == nil })
    #expect(session.repositories.allSatisfy { !$0.createdByVibeManager && $0.failure == nil })
    #expect(session.slug == nil)
    #expect(session.agent?.resumeIdentifier == "thread-9")
  }

  @Test("Reading a v2 document rewrites it as v3, and touches nothing else on disk")
  func v2IsRewrittenWithoutTouchingTheDisk() async throws {
    let storeURL = try makeStoreURL()
    defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
    try Data(v2Document.utf8).write(to: storeURL)

    _ = try await FileSessionRepository(storeURL: storeURL).sessions()

    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 3)
    let sessions = try #require(object["sessions"] as? [[String: Any]])
    let repository = try #require((sessions.first?["repositories"] as? [[String: Any]])?.first)
    #expect(repository["rootPath"] as? String == "/nowhere/vibe-v2/api")
    #expect(repository["mode"] as? String == "inPlace")
    #expect(repository["path"] == nil)
    #expect(!FileManager.default.fileExists(atPath: "/nowhere/vibe-v2"))
  }

  @Test("Everything a v3 repository carries survives a round trip")
  func v3RoundTrip() async throws {
    let storeURL = try makeStoreURL()
    defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
    let attachedAt = Date(timeIntervalSince1970: 1_790_000_000.118)
    let session = WorkSession(
      name: "Refonte de la facturation",
      repositories: [
        RepositoryContext(
          rootPath: "/Users/alice/code/api",
          mode: .worktree,
          worktreePath: "/Users/alice/VibeManager/Worktrees/refonte-facturation/api",
          branchName: "vibe/refonte-facturation",
          baseRevision: "3f2a1c9",
          createdByVibeManager: true,
          attachedAt: attachedAt
        ),
        RepositoryContext(
          rootPath: "/Users/alice/code/web",
          mode: .worktree,
          attachedAt: attachedAt,
          failure: RepositoryPreparationFailure(message: "Git refused.", remedy: "Retry.")
        ),
        RepositoryContext(rootPath: "/Users/alice/notes", mode: .plainFolder),
      ],
      slug: SessionSlug("refonte-facturation")
    )

    try await FileSessionRepository(storeURL: storeURL).save(session)
    let reloaded = try await FileSessionRepository(storeURL: storeURL).sessions()

    #expect(reloaded == [session])
  }

  @Test("A v3 store with a slug Git would refuse is unreadable, and its backup is kept")
  func invalidSlugIsCorruption() async throws {
    let storeURL = try makeStoreURL()
    defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
    let repository = FileSessionRepository(storeURL: storeURL)
    let original = WorkSession(name: "Original", slug: SessionSlug("original"))
    try await repository.save(original)
    try await repository.save(WorkSession(name: "Second", slug: SessionSlug("second")))

    let text = try String(contentsOf: storeURL, encoding: .utf8)
    try Data(text.replacingOccurrences(of: #""second""#, with: #""with space""#).utf8)
      .write(to: storeURL)

    await #expect(throws: SessionStoreError.corruptedStore(backupAvailable: true)) {
      try await repository.sessions()
    }
    try await repository.restoreBackup()
    #expect(try await repository.sessions() == [original])
  }
}
