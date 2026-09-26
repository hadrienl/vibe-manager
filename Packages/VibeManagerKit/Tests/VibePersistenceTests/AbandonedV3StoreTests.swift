import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("Reading back a store written by the abandoned worktree build")
struct AbandonedV3StoreTests {
  private func makeStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeManagerV3-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("sessions.json")
  }

  /// The shape that build wrote: one session migrated in place, one given a worktree.
  private let document = """
    {
      "schemaVersion": 3,
      "savedAt": "2026-09-23T12:31:44.188Z",
      "sessions": [
        {
          "id": "88E8C16B-2824-4CCC-8EF4-C7A1C16EA3AD",
          "name": "In place",
          "initialPrompt": "",
          "agent": { "providerID": "codex", "resumeIdentifier": "thread-123" },
          "appearance": { "symbolName": "terminal", "colorHex": "#5E5CE6" },
          "lifecycle": {
            "status": "closed",
            "createdAt": "2026-09-23T09:00:00.000Z",
            "updatedAt": "2026-09-23T10:00:00.000Z",
            "closedAt": "2026-09-23T10:00:00.000Z"
          },
          "repositories": [
            {
              "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
              "rootPath": "/projects/app",
              "mode": "inPlace",
              "branchName": "main",
              "createdByVibeManager": false
            }
          ]
        },
        {
          "id": "340FE89E-32A8-49A6-B226-87433529B162",
          "name": "Bug restart codex",
          "initialPrompt": "Fix it.",
          "agent": { "providerID": "claude-code", "resumeIdentifier": "a358a5cb" },
          "appearance": { "symbolName": "ladybug", "colorHex": "#5E5CE6" },
          "lifecycle": {
            "status": "archived",
            "createdAt": "2026-09-23T10:19:33.403Z",
            "updatedAt": "2026-09-23T12:31:44.188Z",
            "closedAt": "2026-09-23T10:40:22.250Z",
            "archivedAt": "2026-09-23T12:31:44.188Z",
            "startedAt": "2026-09-23T10:19:34.709Z"
          },
          "repositories": [
            {
              "id": "79CE140C-59FE-4572-BC40-51F6DFAD2E0E",
              "rootPath": "/projects/vibe-manager",
              "mode": "worktree",
              "worktreePath": "/Worktrees/bug-restart-codex/vibe-manager",
              "branchName": "vibe/bug-restart-codex",
              "baseRevision": "3351c18f845c4bbba4449fe1e494009f39ed9e4a",
              "createdByVibeManager": true,
              "attachedAt": "2026-09-23T10:19:33.403Z",
              "baseline": {
                "branches": { "main": "bbb88f49" },
                "capturedAt": "2026-09-23T10:19:35.009Z",
                "checkedOutBranch": "vibe/bug-restart-codex",
                "isDirty": false
              }
            }
          ],
          "slug": "bug-restart-codex"
        }
      ]
    }
    """

  @Test("Every session comes back, each in the folder its agent was started in")
  func sessionsAreKept() async throws {
    let storeURL = try makeStoreURL()
    defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
    try Data(document.utf8).write(to: storeURL)

    let sessions = try await FileSessionRepository(storeURL: storeURL).sessions()

    #expect(sessions.count == 2)
    let inPlace = try #require(sessions.first { $0.name == "In place" })
    #expect(inPlace.repositories.map(\.path) == ["/projects/app"])
    #expect(inPlace.agent?.resumeIdentifier == "thread-123")
    // The conversation of an agent started in a worktree is filed under that worktree: resuming
    // it anywhere else would not find it.
    let worktree = try #require(sessions.first { $0.name == "Bug restart codex" })
    #expect(worktree.repositories.map(\.path) == ["/Worktrees/bug-restart-codex/vibe-manager"])
    #expect(worktree.status == .archived)
  }

  @Test("Reading it rewrites it in the current schema")
  func documentIsRewritten() async throws {
    let storeURL = try makeStoreURL()
    defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
    try Data(document.utf8).write(to: storeURL)

    _ = try await FileSessionRepository(storeURL: storeURL).sessions()

    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: storeURL))
    #expect((object as? [String: Any])?["schemaVersion"] as? Int == 6)
  }
}
