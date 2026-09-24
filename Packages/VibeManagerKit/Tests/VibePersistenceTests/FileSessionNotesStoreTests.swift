import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

private func makeDirectory() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeManagerNotes-\(UUID().uuidString)", isDirectory: true)
    .appendingPathComponent("Notes", isDirectory: true)
}

private func permissions(of url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Suite("Keeping each session's notes in a file of its own")
struct FileSessionNotesStoreTests {
  @Test("A text comes back exactly as it was written, in a UTF-8 file named after the session")
  func roundTrip() async throws {
    let directory = makeDirectory()
    let store = FileSessionNotesStore(directory: directory)
    let id = SessionID()
    // Emoji, a decomposed "é", a tab, and new lines at the end: nothing is trimmed or normalized.
    let text = "Garder l’ancien endpoint 🧭\nCafe\u{301}\tok\n\n"

    let saved = try await store.save(text, for: id)

    #expect(saved.text == text)
    #expect(saved.modifiedAt != nil)
    #expect(try await store.notes(for: id).text == text)
    let file = store.fileURL(for: id)
    #expect(file.lastPathComponent == "\(id.rawValue.uuidString).txt")
    #expect(try Data(contentsOf: file) == Data(text.utf8))
  }

  @Test("A session without notes has none, and emptying them removes the file")
  func emptyMeansNoFile() async throws {
    let store = FileSessionNotesStore(directory: makeDirectory())
    let id = SessionID()
    #expect(try await store.notes(for: id) == .empty)

    try await store.save("Something", for: id)
    try await store.save("", for: id)

    #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: id).path))
    #expect(try await store.notes(for: id) == .empty)
  }

  @Test("The folder is private to the user, and so is every file in it")
  func permissionsAreOwnerOnly() async throws {
    let directory = makeDirectory()
    let store = FileSessionNotesStore(directory: directory)
    let id = SessionID()

    try await store.save("Private", for: id)

    #expect(try permissions(of: directory) == 0o700)
    #expect(try permissions(of: store.fileURL(for: id)) == 0o600)
  }

  @Test("Notes are held to 64 KB: the limit is accepted, one byte more is refused")
  func limit() async throws {
    let store = FileSessionNotesStore(directory: makeDirectory())
    let id = SessionID()
    let atLimit = String(repeating: "a", count: SessionNotesLimits.byteLimit)

    try await store.save(atLimit, for: id)
    await #expect(
      throws: SessionNotesError.tooLarge(
        byteCount: SessionNotesLimits.byteLimit + 1, limit: SessionNotesLimits.byteLimit)
    ) {
      try await store.save(atLimit + "b", for: id)
    }
    #expect(try await store.notes(for: id).text == atLimit)
  }

  @Test("A file already over the limit stays editable down to size, never up")
  func oversizedFileOnlyShrinks() async throws {
    let directory = makeDirectory()
    let store = FileSessionNotesStore(directory: directory)
    let id = SessionID()
    let large = String(repeating: "x", count: 100_000)
    try await store.importNotes(large, for: id)

    try await store.save(String(large.dropLast(10)), for: id)
    await #expect(throws: SessionNotesError.self) {
      try await store.save(large + "more", for: id)
    }
    #expect(try await store.notes(for: id).text.utf8.count == 99_990)
  }

  @Test("A file that is not UTF-8 is unreadable, and is never written over nor removed")
  func unreadableFileIsLeftAlone() async throws {
    let directory = makeDirectory()
    let store = FileSessionNotesStore(directory: directory)
    let id = SessionID()
    try await store.save("placeholder", for: id)
    let bytes = Data([0x66, 0x6F, 0xFF, 0xFE, 0x6F])
    try bytes.write(to: store.fileURL(for: id))

    await #expect(throws: SessionNotesError.self) { try await store.notes(for: id) }
    await #expect(throws: SessionNotesError.self) { try await store.save("new", for: id) }
    await #expect(throws: SessionNotesError.self) { try await store.save("", for: id) }
    await #expect(throws: SessionNotesError.self) { try await store.importNotes("old", for: id) }

    #expect(try Data(contentsOf: store.fileURL(for: id)) == bytes)
    #expect(await store.allNotes()[id] == nil)
  }

  @Test("A write interrupted before its file is moved in leaves the previous notes whole")
  func interruptedWriteKeepsThePreviousVersion() async throws {
    let directory = makeDirectory()
    let id = SessionID()
    try await FileSessionNotesStore(directory: directory).save("Before", for: id)

    struct Interrupted: Error {}
    let failing = FileSessionNotesStore(
      directory: directory, beforeReplace: { throw Interrupted() })
    await #expect(throws: SessionNotesError.self) {
      try await failing.save("After", for: id)
    }

    #expect(try await failing.notes(for: id).text == "Before")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(leftovers == ["\(id.rawValue.uuidString).txt"])
  }

  @Test("Every readable session's notes are listed for the search, and nothing else")
  func allNotesForTheSearch() async throws {
    let directory = makeDirectory()
    let store = FileSessionNotesStore(directory: directory)
    let first = SessionID()
    let second = SessionID()
    try await store.save("First", for: first)
    try await store.save("Second", for: second)
    try Data("stray".utf8).write(to: directory.appendingPathComponent("README.txt"))
    try Data("hidden".utf8).write(to: directory.appendingPathComponent(".tmp.txt"))

    #expect(await store.allNotes() == [first: "First", second: "Second"])
  }

  @Test("Importing writes notes that are not there yet, and never replaces notes that are")
  func importNeverReplaces() async throws {
    let store = FileSessionNotesStore(directory: makeDirectory())
    let fresh = SessionID()
    let written = SessionID()
    try await store.save("Typed since", for: written)

    try await store.importNotes("Imported", for: fresh)
    try await store.importNotes("Imported", for: written)

    #expect(try await store.notes(for: fresh).text == "Imported")
    #expect(try await store.notes(for: written).text == "Typed since")
  }
}

@Suite("Importing the notes an older store kept inside its sessions")
struct ImportLegacyNotesTests {
  private func storeURL() -> URL {
    makeDirectory().deletingLastPathComponent().appendingPathComponent("sessions.json")
  }

  @Test("Notes found in a session are written to their file, then cleared from the session")
  func importsThenClears() async throws {
    let repository = FileSessionRepository(storeURL: storeURL())
    let notes = FileSessionNotesStore(directory: makeDirectory())
    let withNotes = WorkSession(name: "Old", legacyNotes: "Written before #16")
    let without = WorkSession(name: "Plain")
    try await repository.save(withNotes)
    try await repository.save(without)

    let cleared = await ImportLegacyNotes(repository: repository, notes: notes)()

    #expect(cleared == [withNotes.id])
    #expect(try await notes.notes(for: withNotes.id).text == "Written before #16")
    #expect(try await repository.session(id: withNotes.id)?.legacyNotes == nil)
    #expect(await notes.allNotes().count == 1)
  }

  @Test("Interrupted after the file was written, the next launch only clears the session")
  func interruptedImportFinishesWithoutLoss() async throws {
    let url = storeURL()
    let notes = FileSessionNotesStore(directory: makeDirectory())
    let session = WorkSession(name: "Old", legacyNotes: "Written before #16")
    try await FileSessionRepository(storeURL: url).save(session)

    // The first launch writes the file and fails to clear the session.
    let refusing = RefusingMutations(base: FileSessionRepository(storeURL: url))
    #expect(await ImportLegacyNotes(repository: refusing, notes: notes)().isEmpty)
    #expect(try await notes.notes(for: session.id).text == "Written before #16")
    // Meanwhile the user edits the imported notes.
    try await notes.save("Edited since", for: session.id)

    let repository = FileSessionRepository(storeURL: url)
    #expect(await ImportLegacyNotes(repository: repository, notes: notes)() == [session.id])
    #expect(try await notes.notes(for: session.id).text == "Edited since")
    #expect(try await repository.session(id: session.id)?.legacyNotes == nil)
  }

  @Test("Notes that cannot be written stay in the session, for the next launch")
  func failedWriteKeepsTheField() async throws {
    let repository = FileSessionRepository(storeURL: storeURL())
    let session = WorkSession(name: "Old", legacyNotes: "Written before #16")
    try await repository.save(session)

    #expect(await ImportLegacyNotes(repository: repository, notes: NoSessionNotes())().isEmpty)
    #expect(try await repository.session(id: session.id)?.legacyNotes == "Written before #16")
  }
}

private actor RefusingMutations: SessionRepository {
  let base: FileSessionRepository

  init(base: FileSessionRepository) {
    self.base = base
  }

  func sessions() async throws -> [WorkSession] { try await base.sessions() }
  func session(id: SessionID) async throws -> WorkSession? { try await base.session(id: id) }
  func save(_ session: WorkSession) async throws { try await base.save(session) }
  func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) async throws -> WorkSession? {
    throw SessionStoreError.cannotAccessStore
  }
}
