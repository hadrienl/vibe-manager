import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("Migrating a schema v1 store to v2")
struct SessionStoreMigrationTests {
  private func makeStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeManagerMigration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("sessions.json")
  }

  private func document(modelID: String) -> String {
    """
    {
      "schemaVersion": 1,
      "savedAt": "2026-09-21T10:00:00.000Z",
      "sessions": [
        {
          "id": "88E8C16B-2824-4CCC-8EF4-C7A1C16EA3AD",
          "name": "Stored before the migration",
          "initialPrompt": "Split the signature check out.",
          "agent": {
            "providerID": "codex",
            "modelID": "\(modelID)",
            "resumeIdentifier": "thread-123"
          },
          "appearance": { "symbolName": "terminal", "colorHex": "#5E5CE6" },
          "lifecycle": {
            "status": "closed",
            "createdAt": "2026-09-21T09:00:00.000Z",
            "updatedAt": "2026-09-21T10:00:00.000Z",
            "closedAt": "2026-09-21T10:00:00.000Z"
          },
          "repositories": [
            { "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "path": "/projects/app" }
          ]
        }
      ]
    }
    """
  }

  @Test("A session stored before the first launch was recorded is not read as never launched")
  func v1SessionIsReadAsHavingRun() async throws {
    let storeURL = try makeStoreURL()
    defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
    try Data(document(modelID: "gpt-6-astra").utf8).write(to: storeURL)

    let sessions = try await FileSessionRepository(storeURL: storeURL).sessions()

    // Closed an hour after it was created, so it ran. Read as never started it would be offered
    // a first launch, and handed its own creation prompt in place of its conversation.
    let session = try #require(sessions.first)
    #expect(session.hasEverStarted)
  }

  @Test("A v1 session keeps its model, its resume identifier and its repositories")
  func v1SessionIsPreserved() async throws {
    let storeURL = try makeStoreURL()
    defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
    try Data(document(modelID: "gpt-6-astra").utf8).write(to: storeURL)

    let sessions = try await FileSessionRepository(storeURL: storeURL).sessions()

    let session = try #require(sessions.first)
    #expect(session.name == "Stored before the migration")
    #expect(session.agent?.modelID == "gpt-6-astra")
    #expect(session.agent?.resumeIdentifier == "thread-123")
    #expect(session.repositories.map(\.path) == ["/projects/app"])
  }

  @Test("Reading a v1 document rewrites it in the current schema")
  func v1DocumentIsRewritten() async throws {
    let storeURL = try makeStoreURL()
    defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
    try Data(document(modelID: "gpt-6-astra").utf8).write(to: storeURL)

    _ = try await FileSessionRepository(storeURL: storeURL).sessions()

    let rewritten = try JSONSerialization.jsonObject(with: try Data(contentsOf: storeURL))
    let object = try #require(rewritten as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 7)
  }

  @Test("An empty v1 model becomes no model, never a model named nothing")
  func emptyModelBecomesNil() async throws {
    let storeURL = try makeStoreURL()
    defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
    try Data(document(modelID: "").utf8).write(to: storeURL)

    let sessions = try await FileSessionRepository(storeURL: storeURL).sessions()

    #expect(try #require(sessions.first).agent?.modelID == nil)
  }

  @Test("A session saved without a model survives a round trip")
  func modellessSessionRoundTrips() async throws {
    let storeURL = try makeStoreURL()
    defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
    let repository = FileSessionRepository(storeURL: storeURL)
    var session = WorkSession(name: "No model chosen")
    session.agent = SessionAgentConfiguration(providerID: "claude-code")

    try await repository.save(session)
    let reloaded = try await FileSessionRepository(storeURL: storeURL).sessions()

    #expect(try #require(reloaded.first).agent?.modelID == nil)
    #expect(try #require(reloaded.first).agent?.providerID == "claude-code")
  }
}
