import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibePersistence

/// The batches on disk (#408): one file each, private, read back, removed.
@Suite("The archive reports' files (#408)")
struct FileArchiveReportStoreTests {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("ArchiveReports-\(UUID().uuidString)", isDirectory: true)

  @Test("A batch is written private, read back, and removed past the retention or on demand")
  func roundTrip() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileArchiveReportStore(directory: directory)
    let date = Date(timeIntervalSince1970: 1_792_695_600)
    let snapshot = ArchivedSessionSnapshot(
      sessionID: SessionID(), archivedAt: date, name: "Icons", colorHex: "#B42318",
      symbolName: "hammer", createdAt: date,
      entries: [JournalEntry(text: "Moved the icons", at: date, providerID: "claude")])
    let old = ArchiveBatch(kind: .manual, date: date.addingTimeInterval(-400 * 86_400))
    let batch = ArchiveBatch(
      kind: .rule(id: UUID(), name: "Evening"), date: date, sessions: [snapshot],
      synthesis: .ready(text: "Done.", providerID: "claude", at: date))
    try await store.save(old)
    try await store.save(batch)

    #expect(await store.batches() == [old, batch])
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(files.contains("2026-10-22-\(batch.id.uuidString).json"))
    let mode =
      try FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent(files[0]).path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    // A file that does not read is left alone, and does not hide the others.
    try Data("{".utf8).write(to: directory.appendingPathComponent("broken.json"))
    #expect(await store.batches().count == 2)

    #expect(await store.removeBatches(before: date.addingTimeInterval(-86_400)) == 1)
    #expect(await store.batches() == [batch])
    try await store.removeAll()
    #expect(await store.batches().isEmpty)
  }
}
