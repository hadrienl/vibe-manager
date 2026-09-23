import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("The runtime document")
struct FileSessionRuntimeStateStoreTests {
  private func url() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("vibe-runtime-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("runtime.json", isDirectory: false)
  }

  private func state(
    phase: SessionRuntimeState.Phase = .running,
    sessions: [SessionRuntimeRecord]
  ) -> SessionRuntimeState {
    SessionRuntimeState(
      phase: phase,
      processIdentifier: 4_242,
      launchedAt: Date(timeIntervalSince1970: 1_700_000_000.125),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_600.5),
      stoppedAt: phase == .stopped ? Date(timeIntervalSince1970: 1_700_000_600.5) : nil,
      sessions: sessions
    )
  }

  @Test("A written document comes back exactly as it was written")
  func roundTrip() async {
    let store = FileSessionRuntimeStateStore(url: url())
    let written = state(
      phase: .running,
      sessions: [
        SessionRuntimeRecord(
          sessionID: SessionID(),
          processGroup: 7_001,
          processStartedAt: Date(timeIntervalSince1970: 1_700_000_050.75)
        ),
        SessionRuntimeRecord(sessionID: SessionID()),
      ]
    )

    await store.write(written)

    #expect(await store.read() == written)
  }

  @Test("The identifiers are written as plain strings, openable by hand")
  func writesReadableJSON() async throws {
    let location = url()
    let store = FileSessionRuntimeStateStore(url: location)
    let id = SessionID()

    await store.write(state(sessions: [SessionRuntimeRecord(sessionID: id, processGroup: 7_001)]))

    let text = try String(contentsOf: location, encoding: .utf8)
    #expect(text.contains("\"sessionID\" : \"\(id.rawValue.uuidString)\""))
    #expect(text.contains("\"schemaVersion\" : 1"))
  }

  @Test("A damaged document is an absence, not an error")
  func damagedDocumentReadsAsNothing() async throws {
    let location = url()
    try FileManager.default.createDirectory(
      at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("this is not the document you are looking for".utf8).write(to: location)

    #expect(await FileSessionRuntimeStateStore(url: location).read() == nil)
  }

  @Test("A document from a newer build is passed over rather than guessed at")
  func unknownSchemaVersionReadsAsNothing() async throws {
    let location = url()
    try FileManager.default.createDirectory(
      at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
    let document = """
      {
        "schemaVersion" : 99,
        "state" : {
          "phase" : "stopped",
          "processIdentifier" : 4242,
          "launchedAt" : "2026-09-22T09:12:04.118Z",
          "updatedAt" : "2026-09-22T11:47:31.002Z",
          "sessions" : []
        }
      }
      """
    try Data(document.utf8).write(to: location)

    #expect(await FileSessionRuntimeStateStore(url: location).read() == nil)
  }

  @Test("A missing document is an absence too")
  func missingDocumentReadsAsNothing() async {
    #expect(await FileSessionRuntimeStateStore(url: url()).read() == nil)
  }

  @Test("Clearing it leaves nothing behind")
  func clearRemovesTheDocument() async {
    let location = url()
    let store = FileSessionRuntimeStateStore(url: location)
    await store.write(state(sessions: []))

    await store.clear()

    #expect(await store.read() == nil)
    #expect(!FileManager.default.fileExists(atPath: location.path))
  }

  @Test("The document is readable by its owner alone")
  func writesOwnerOnlyPermissions() async throws {
    let location = url()
    await FileSessionRuntimeStateStore(url: location).write(state(sessions: []))

    let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
  }
}
