import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

private enum TestWriteError: Error {
  case interrupted
}

private func makeStoreURL() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeManagerTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.appendingPathComponent("sessions.json")
}

private func makeCompleteSession(name: String = "Persistent session") -> WorkSession {
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  return WorkSession(
    name: name,
    initialPrompt: "Build the persistence layer 🗃️",
    agent: SessionAgentConfiguration(
      providerID: "codex",
      modelID: "gpt-5",
      resumeIdentifier: "thread-123"
    ),
    appearance: SessionAppearance(symbolName: "externaldrive.fill", colorHex: "#FF9500"),
    status: .active,
    createdAt: date,
    updatedAt: date,
    repositories: [
      RepositoryContext(
        rootPath: "/projects/vibe-manager",
        git: GitSnapshot(
          repositoryRootPath: "/projects/vibe-manager",
          worktreePath: "/worktrees/persistence",
          branchName: "feature/persistence",
          headRevision: "abc123",
          isDirty: true,
          capturedAt: date
        )
      )
    ],
    notes: "A user-authored note",
    template: PromptTemplateReference(id: "implement", name: "Implement", revision: "2")
  )
}

@Test("A complete session survives repository recreation")
func fileRepositoryRoundTrip() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let session = makeCompleteSession()

  try await FileSessionRepository(storeURL: storeURL).save(session)
  let reloaded = try await FileSessionRepository(storeURL: storeURL).sessions()

  #expect(reloaded == [session])
}

@Test("The store uses restrictive permissions and a field allowlist")
func filePermissionsAndAllowlist() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  // The repository creates its own container here, which is the directory it is allowed to
  // restrict; a caller-provided directory that already exists keeps its own permissions.
  let containerURL = storeURL.deletingLastPathComponent()
    .appendingPathComponent("container", isDirectory: true)
  let containedStoreURL = containerURL.appendingPathComponent("sessions.json")
  let repository = FileSessionRepository(storeURL: containedStoreURL)

  try await repository.save(makeCompleteSession())

  let fileAttributes = try FileManager.default.attributesOfItem(atPath: containedStoreURL.path)
  let directoryAttributes = try FileManager.default.attributesOfItem(atPath: containerURL.path)
  #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

  let contents = try String(contentsOf: containedStoreURL, encoding: .utf8)
  #expect(!contents.contains("terminalOutput"))
  #expect(!contents.contains("environment"))
  #expect(!contents.contains("accessToken"))
  #expect(!contents.contains("remoteURL"))
}

@Test("A V0 fixture migrates to the current schema")
func legacyStoreMigration() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let legacy = """
    {
      "schemaVersion": 0,
      "savedAt": "2026-09-21T10:00:00.000Z",
      "sessions": [
        {
          "id": "88E8C16B-2824-4CCC-8EF4-C7A1C16EA3AD",
          "name": "Legacy session",
          "status": "closed",
          "createdAt": "2026-09-21T09:00:00.000Z",
          "updatedAt": "2026-09-21T10:00:00.000Z"
        }
      ]
    }
    """
  try Data(legacy.utf8).write(to: storeURL)

  let sessions = try await FileSessionRepository(storeURL: storeURL).sessions()

  #expect(sessions.count == 1)
  #expect(sessions.first?.name == "Legacy session")
  #expect(sessions.first?.agent == nil)
  let migratedData = try Data(contentsOf: storeURL)
  let rawObject = try JSONSerialization.jsonObject(with: migratedData)
  let object = try #require(rawObject as? [String: Any])
  #expect(object["schemaVersion"] as? Int == 3)
}

@Test("A future schema is rejected without modifying the store")
func futureSchemaIsRejected() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let future = Data("{\"schemaVersion\":99,\"savedAt\":\"future\",\"sessions\":[]}".utf8)
  try future.write(to: storeURL)

  do {
    _ = try await FileSessionRepository(storeURL: storeURL).sessions()
    Issue.record("Expected the future schema to be rejected")
  } catch {
    #expect(error as? SessionStoreError == .unsupportedSchemaVersion(99))
  }
  #expect(try Data(contentsOf: storeURL) == future)
}

@Test("A corrupt primary store reports and restores its valid backup")
func corruptStoreRecovery() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let repository = FileSessionRepository(storeURL: storeURL)
  let original = makeCompleteSession(name: "Original")
  var updated = original
  updated.name = "Updated"

  try await repository.save(original)
  try await repository.save(updated)
  try Data("{truncated".utf8).write(to: storeURL)

  do {
    _ = try await repository.sessions()
    Issue.record("Expected the corrupt store to fail")
  } catch {
    #expect(error as? SessionStoreError == .corruptedStore(backupAvailable: true))
  }
  #expect(await repository.recoveryStatus() == .backupAvailable)

  try await repository.restoreBackup()
  #expect(try await repository.sessions() == [original])
  #expect(await repository.recoveryStatus() == .notNeeded)
}

@Test("An interruption before replacement preserves the previous store")
func interruptedWritePreservesStore() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let original = makeCompleteSession(name: "Original")
  try await FileSessionRepository(storeURL: storeURL).save(original)
  let interruptedRepository = FileSessionRepository(storeURL: storeURL) {
    throw TestWriteError.interrupted
  }
  var updated = original
  updated.name = "Should not be committed"

  do {
    try await interruptedRepository.save(updated)
    Issue.record("Expected the write to be interrupted")
  } catch {
    #expect(error as? SessionStoreError == .cannotAccessStore)
  }

  let reloaded = try await FileSessionRepository(storeURL: storeURL).sessions()
  #expect(reloaded == [original])
}

@Test("Duplicate identifiers are treated as recoverable corruption")
func duplicateIdentifiersAreRejected() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let repository = FileSessionRepository(storeURL: storeURL)
  try await repository.save(makeCompleteSession())
  let validData = try Data(contentsOf: storeURL)
  let rawObject = try JSONSerialization.jsonObject(with: validData)
  var object = try #require(rawObject as? [String: Any])
  let sessions = try #require(object["sessions"] as? [[String: Any]])
  object["sessions"] = sessions + sessions
  let duplicateData = try JSONSerialization.data(withJSONObject: object)
  try duplicateData.write(to: storeURL)

  do {
    _ = try await repository.sessions()
    Issue.record("Expected duplicate identifiers to be rejected")
  } catch {
    #expect(error as? SessionStoreError == .corruptedStore(backupAvailable: false))
  }
  #expect(try Data(contentsOf: storeURL) == duplicateData)
}

@Test("A healthy store refuses to be rewound to its backup")
func restoreIsRefusedOnHealthyStore() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let repository = FileSessionRepository(storeURL: storeURL)
  let original = makeCompleteSession(name: "Original")
  var updated = original
  updated.name = "Updated"

  try await repository.save(original)
  try await repository.save(updated)

  await #expect(throws: SessionStoreError.recoveryNotNeeded) {
    try await repository.restoreBackup()
  }
  #expect(try await repository.sessions() == [updated])
}

@Test("A migration that cannot be written back still returns its sessions")
func migrationSurvivesUnwritableStore() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let legacy = """
    {
      "schemaVersion": 0,
      "savedAt": "2026-09-21T10:00:00.000Z",
      "sessions": [
        {
          "id": "88E8C16B-2824-4CCC-8EF4-C7A1C16EA3AD",
          "name": "Legacy session",
          "status": "closed",
          "createdAt": "2026-09-21T09:00:00.000Z",
          "updatedAt": "2026-09-21T10:00:00.000Z"
        }
      ]
    }
    """
  let legacyData = Data(legacy.utf8)
  try legacyData.write(to: storeURL)
  let repository = FileSessionRepository(storeURL: storeURL) {
    throw TestWriteError.interrupted
  }

  let sessions = try await repository.sessions()

  #expect(sessions.map(\.name) == ["Legacy session"])
  #expect(try Data(contentsOf: storeURL) == legacyData)
}

@Test("Concurrent mutations are serialized by the store")
func concurrentMutationsAreSerialized() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let repository = FileSessionRepository(storeURL: storeURL)
  let session = makeCompleteSession()
  try await repository.save(session)

  await withTaskGroup(of: Void.self) { group in
    for _ in 0..<10 {
      group.addTask {
        _ = try? await repository.mutate(id: session.id) { stored in
          stored.notes = (stored.notes ?? "") + "x"
        }
      }
    }
  }

  let reloaded = try await repository.session(id: session.id)
  #expect(reloaded?.notes == "A user-authored note" + String(repeating: "x", count: 10))
}

@Test("A store from a newer version is never rewound to an older backup")
func futureSchemaIsNotRecoverable() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let backupURL = storeURL.deletingPathExtension().appendingPathExtension("backup.json")
  let repository = FileSessionRepository(storeURL: storeURL)

  try await repository.save(makeCompleteSession(name: "Stale"))
  try FileManager.default.copyItem(at: storeURL, to: backupURL)
  let future = Data("{\"schemaVersion\":99,\"savedAt\":\"future\",\"sessions\":[]}".utf8)
  try future.write(to: storeURL)

  #expect(await repository.recoveryStatus() == .unsupportedVersion)
  await #expect(throws: SessionStoreError.recoveryRefusedForNewerStore) {
    try await repository.restoreBackup()
  }
  #expect(try Data(contentsOf: storeURL) == future)
}

@Test("An unreadable store is never restored over")
func unreadableStoreIsNotRestorable() async throws {
  let storeURL = try makeStoreURL()
  defer {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: storeURL.path
    )
    try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
  }
  let backupURL = storeURL.deletingPathExtension().appendingPathExtension("backup.json")
  let repository = FileSessionRepository(storeURL: storeURL)

  try await repository.save(makeCompleteSession(name: "Stale"))
  try FileManager.default.copyItem(at: storeURL, to: backupURL)
  try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: storeURL.path)

  #expect(await repository.recoveryStatus() == .storeUnreadable)
  await #expect(throws: SessionStoreError.cannotAccessStore) {
    try await repository.restoreBackup()
  }
}

@Test("Saving over a legacy store keeps the pre-migration document as backup")
func savingALegacyStoreBacksUpTheOriginalDocument() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let backupURL = storeURL.deletingPathExtension().appendingPathExtension("backup.json")
  let legacy = """
    {
      "schemaVersion": 0,
      "savedAt": "2026-09-21T10:00:00.000Z",
      "sessions": [
        {
          "id": "88E8C16B-2824-4CCC-8EF4-C7A1C16EA3AD",
          "name": "Legacy session",
          "status": "closed",
          "createdAt": "2026-09-21T09:00:00.000Z",
          "updatedAt": "2026-09-21T10:00:00.000Z"
        }
      ]
    }
    """
  try Data(legacy.utf8).write(to: storeURL)
  let repository = FileSessionRepository(storeURL: storeURL)

  try await repository.save(makeCompleteSession(name: "New"))

  // A mutation commits once, so the backup still holds the document the migration replaced
  // rather than an already migrated copy of it.
  let backupObject = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: backupURL)) as? [String: Any]
  )
  #expect(backupObject["schemaVersion"] as? Int == 0)
  #expect(try await repository.sessions().map(\.name).sorted() == ["Legacy session", "New"])
}

@Test("A caller-provided directory keeps its own permissions")
func existingDirectoryPermissionsAreLeftAlone() async throws {
  let storeURL = try makeStoreURL()
  let directory = storeURL.deletingLastPathComponent()
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

  try await FileSessionRepository(storeURL: storeURL).save(makeCompleteSession())

  let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
}

@Test("Sub-millisecond timestamps survive a round trip")
func subMillisecondDatesRoundTrip() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let repository = FileSessionRepository(storeURL: storeURL)
  var saved: [WorkSession] = []

  for index in 0..<50 {
    let now = Date()
    var session = makeCompleteSession(name: "Session \(index)")
    session = WorkSession(
      id: session.id,
      name: session.name,
      status: .active,
      createdAt: now,
      updatedAt: now
    )
    try await repository.save(session)
    saved.append(session)
  }

  let reloaded = try await repository.sessions()
  #expect(Set(reloaded) == Set(saved))
}
