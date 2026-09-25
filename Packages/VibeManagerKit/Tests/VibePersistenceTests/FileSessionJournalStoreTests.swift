import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("The journals on disk")
struct FileSessionJournalStoreTests {
  private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeJournalStore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("Written and read back, one owner-only file per session in an owner-only folder")
  func roundTrip() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Journal")
    let store = FileSessionJournalStore(directory: directory)
    let id = SessionID()
    #expect(try await store.journal(for: id) == nil)
    var journal = SessionJournal()
    journal.append([
      JournalEntry(
        text: "Pushed", at: Date(timeIntervalSince1970: 1_800_000_000), providerID: "codex")
    ])
    try await store.save(journal, for: id)
    #expect(try await store.journal(for: id) == journal)
    let file = store.fileURL(for: id)
    let fileMode =
      try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    let folderMode =
      try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
    #expect(fileMode == 0o600)
    #expect(folderMode == 0o700)
    // A second store, as after a relaunch.
    #expect(try await FileSessionJournalStore(directory: directory).journal(for: id) == journal)
  }

  @Test("A file that cannot be read is never written over")
  func unreadable() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileSessionJournalStore(directory: root)
    let id = SessionID()
    try Data("not json".utf8).write(to: store.fileURL(for: id))
    await #expect(throws: SessionJournalStoreError.unreadable) { try await store.journal(for: id) }
    await #expect(throws: SessionJournalStoreError.unreadable) {
      try await store.save(SessionJournal(), for: id)
    }
    #expect(try Data(contentsOf: store.fileURL(for: id)) == Data("not json".utf8))
  }
}
