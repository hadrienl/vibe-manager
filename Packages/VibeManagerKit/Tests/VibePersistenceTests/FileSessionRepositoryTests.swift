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

private func makeCompleteSession(
  name: String = "Persistent session",
  date: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> WorkSession {
  WorkSession(
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
        path: "/projects/vibe-manager",
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
    legacyNotes: "A user-authored note",
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

@Test("A read after another writer changed the store returns what it wrote")
func readSeesAnotherWriter() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let reader = FileSessionRepository(storeURL: storeURL)
  var session = makeCompleteSession(name: "Before")

  try await reader.save(session)
  #expect(try await reader.session(id: session.id)?.name == "Before")
  session.name = "After"
  try await FileSessionRepository(storeURL: storeURL).save(session)

  #expect(try await reader.session(id: session.id)?.name == "After")
}

@Test("Dates keep their fractions of a second through the store")
func fractionalDatesRoundTrip() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let session = makeCompleteSession(date: Date(timeIntervalSince1970: 1_700_000_000.25))

  try await FileSessionRepository(storeURL: storeURL).save(session)
  let reloaded = try await FileSessionRepository(storeURL: storeURL).session(id: session.id)

  #expect(reloaded?.createdAt == session.createdAt)
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
  #expect(object["schemaVersion"] as? Int == 8)
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

@Test("The damaged bytes are kept owner only, whatever mode the damaged store had")
func quarantinedStoreIsPrivate() async throws {
  let storeURL = try makeStoreURL()
  let directory = storeURL.deletingLastPathComponent()
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = FileSessionRepository(storeURL: storeURL)
  try await repository.save(makeCompleteSession(name: "Original"))
  try await repository.save(makeCompleteSession(name: "Updated"))
  try Data("{truncated".utf8).write(to: storeURL)
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storeURL.path)
  _ = try? await repository.sessions()

  try await repository.restoreBackup()

  let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    .filter { $0.contains(".corrupt-") }
  #expect(quarantined.count == 1)
  for name in quarantined {
    let attributes = try FileManager.default.attributesOfItem(
      atPath: directory.appendingPathComponent(name).path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
  }
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
          stored.legacyNotes = (stored.legacyNotes ?? "") + "x"
        }
      }
    }
  }

  let reloaded = try await repository.session(id: session.id)
  #expect(reloaded?.legacyNotes == "A user-authored note" + String(repeating: "x", count: 10))
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
    // Each new session enters above the last one (#44).
    session.rank = -index
    saved.append(session)
  }

  let reloaded = try await repository.sessions()
  #expect(Set(reloaded) == Set(saved))
}

/// A switch the interruption hook reads, so that one repository can both succeed and fail.
private final class WriteSwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var failing = false

  var fails: Bool {
    get { lock.withLock { failing } }
    set { lock.withLock { failing = newValue } }
  }
}

@Test("The store is not decoded again after its own writes")
func ownWritesAreNotDecodedAgain() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let repository = FileSessionRepository(storeURL: storeURL)
  let session = makeCompleteSession()

  try await repository.save(session)
  _ = try await repository.session(id: session.id)
  _ = try await repository.sessions()
  _ = try await repository.mutate(id: session.id) { $0.name = "Renamed" }
  _ = try await repository.session(id: session.id)
  try await repository.reorder([session.id: 7])
  let reloaded = try await repository.sessions()

  #expect(reloaded.map(\.name) == ["Renamed"])
  #expect(reloaded.map(\.rank) == [7])
  #expect(await repository.decodeCount == 0)
}

@Test("Restoring thirty sessions of a large store decodes it once")
func restorationDecodesOnce() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let sessions = (0..<237).map { makeCompleteSession(name: "Session \($0)") }
  try SessionStoreCodec().encode(sessions: sessions).write(to: storeURL)
  let ids = sessions.map(\.id)
  let launched = FileSessionRepository(storeURL: storeURL)

  // What a restoration does for each session: read its name, read it again to launch it, then
  // write its status and its resume identifier.
  for id in ids.prefix(30) {
    _ = try await launched.session(id: id)?.name
    _ = try await launched.session(id: id)
    _ = try await launched.mutate(id: id) { try $0.close(at: Date()) }
    _ = try await launched.mutate(id: id) { $0.agent?.resumeIdentifier = "thread-\(id)" }
  }

  #expect(await launched.decodeCount <= 1)
}

@Test("What the store keeps after writing is what a cold read of the file gives")
func cacheMatchesTheFile() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let repository = FileSessionRepository(storeURL: storeURL)
  var sessions: [WorkSession] = []
  for index in 0..<5 {
    // Dates below the millisecond, as `Date()` gives them.
    sessions.append(makeCompleteSession(name: "Session \(index)", date: Date()))
    try await repository.save(sessions[index])
  }

  _ = try await repository.mutate(id: sessions[0].id) { session in
    try session.close(at: Date())
    try session.switchAgent(
      to: SessionAgentConfiguration(providerID: "claude-code", modelID: "opus"),
      handover: .nothing, at: Date())
  }
  _ = try await repository.mutate(id: sessions[1].id) { session in
    try session.close(at: Date())
    try session.archive(at: Date())
  }
  _ = try await repository.mutate(id: sessions[2].id) {
    try $0.setTaskStatus(.waiting, at: Date())
  }
  try await repository.reorder([sessions[3].id: 40, sessions[4].id: -40])

  let cached = try await repository.sessions()
  let cold = try await FileSessionRepository(storeURL: storeURL).sessions()
  #expect(cached == cold)
}

@Test("A migrated store kept after writing is what a cold read of the file gives")
func migratedCacheMatchesTheFile() async throws {
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
  let repository = FileSessionRepository(storeURL: storeURL)

  let migrated = try await repository.sessions()
  try await repository.save(makeCompleteSession(name: "New"))

  let cold = try await FileSessionRepository(storeURL: storeURL).sessions()
  #expect(try await repository.sessions() == cold)
  #expect(migrated.map(\.id) == cold.filter { $0.name == "Legacy session" }.map(\.id))
}

@Test("A write that fails leaves what the store kept untouched")
func failedWriteKeepsTheCache() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let writes = WriteSwitch()
  let repository = FileSessionRepository(storeURL: storeURL) {
    if writes.fails { throw TestWriteError.interrupted }
  }
  let original = makeCompleteSession(name: "Original")
  try await repository.save(original)
  var updated = original
  updated.name = "Never written"

  writes.fails = true
  await #expect(throws: SessionStoreError.cannotAccessStore) {
    try await repository.save(updated)
  }

  #expect(try await repository.sessions() == [original])
  #expect(await repository.decodeCount == 0)
}

private func inode(of url: URL) throws -> Int {
  try #require(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
}

@Test(
  "The backup holds the document before the last change, linked or copied",
  arguments: [true, false])
func backupHoldsThePreviousDocument(backsUpByLink: Bool) async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let backupURL = storeURL.deletingPathExtension().appendingPathExtension("backup.json")
  let repository = FileSessionRepository(storeURL: storeURL, backsUpByLink: backsUpByLink)
  let session = makeCompleteSession(name: "First")
  try await repository.save(session)

  _ = try await repository.mutate(id: session.id) { $0.name = "Second" }
  _ = try await repository.mutate(id: session.id) { $0.name = "Third" }

  let backup = try await FileSessionRepository(storeURL: backupURL).sessions()
  #expect(backup.map(\.name) == ["Second"])
  #expect(try await FileSessionRepository(storeURL: storeURL).sessions().map(\.name) == ["Third"])
  #expect(try inode(of: storeURL) != inode(of: backupURL))
  let attributes = try FileManager.default.attributesOfItem(atPath: backupURL.path)
  #expect(attributes[.posixPermissions] as? Int == 0o600)
  let leftovers = try FileManager.default.contentsOfDirectory(
    atPath: storeURL.deletingLastPathComponent().path
  ).filter { $0.hasSuffix(".tmp") }
  #expect(leftovers.isEmpty)
}

@Test("A write after a failed one leaves no temporary file and parts the backup from the store")
func writeAfterFailedWriteLeavesNothingBehind() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let backupURL = storeURL.deletingPathExtension().appendingPathExtension("backup.json")
  let writes = WriteSwitch()
  let repository = FileSessionRepository(storeURL: storeURL) {
    if writes.fails { throw TestWriteError.interrupted }
  }
  let session = makeCompleteSession(name: "First")
  try await repository.save(session)

  writes.fails = true
  _ = try? await repository.mutate(id: session.id) { $0.name = "Never written" }
  writes.fails = false
  _ = try await repository.mutate(id: session.id) { $0.name = "Second" }

  let leftovers = try FileManager.default.contentsOfDirectory(
    atPath: storeURL.deletingLastPathComponent().path
  ).filter { $0.hasSuffix(".tmp") }
  #expect(leftovers.isEmpty)
  #expect(try inode(of: storeURL) != inode(of: backupURL))
  #expect(try await FileSessionRepository(storeURL: backupURL).sessions().map(\.name) == ["First"])
  #expect(try await FileSessionRepository(storeURL: storeURL).sessions().map(\.name) == ["Second"])
}

@Test("A temporary file a crash left behind is removed at the next write")
func orphanedTemporaryFilesAreRemoved() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let directory = storeURL.deletingLastPathComponent()
  let orphan = directory.appendingPathComponent(".sessions.backup.json.\(UUID().uuidString).tmp")
  let unrelated = directory.appendingPathComponent(".other.json.\(UUID().uuidString).tmp")
  for url in [orphan, unrelated] {
    try Data("x".utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: url.path)
  }

  try await FileSessionRepository(storeURL: storeURL).save(makeCompleteSession())

  #expect(!FileManager.default.fileExists(atPath: orphan.path))
  #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

@Test("A store written openly by someone else is backed up owner only")
func linkedBackupIsPrivate() async throws {
  let storeURL = try makeStoreURL()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let backupURL = storeURL.deletingPathExtension().appendingPathExtension("backup.json")
  let session = makeCompleteSession()
  try SessionStoreCodec().encode(sessions: [session]).write(to: storeURL)
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storeURL.path)

  _ = try await FileSessionRepository(storeURL: storeURL).mutate(id: session.id) {
    $0.name = "Changed"
  }

  let attributes = try FileManager.default.attributesOfItem(atPath: backupURL.path)
  #expect(attributes[.posixPermissions] as? Int == 0o600)
}
