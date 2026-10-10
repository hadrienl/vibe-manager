import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("Keeping coordinators and their children in the store")
struct SessionCoordinationStoreTests {
  private func session(
    _ name: String, id: SessionID = SessionID(), coordination: SessionCoordination? = nil
  ) -> WorkSession {
    WorkSession(
      id: id, name: name, createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 100), coordination: coordination)
  }

  @Test("A v10 store keeps a coordinator, its children and the ordinary sessions")
  func roundTrip() throws {
    let codec = SessionStoreCodec()
    let parent = SessionID()
    let sessions = [
      session("V2", id: parent, coordination: .coordinator),
      session("#351", coordination: .child(of: parent)),
      session("Alone"),
    ]

    let decoded = try codec.decode(try codec.encode(sessions: sessions))

    #expect(!decoded.requiresRewrite)
    #expect(decoded.sessions.map(\.coordination) == [.coordinator, .child(of: parent), nil])
  }

  @Test("A v9 store has ordinary sessions only, and is rewritten in v10")
  func v9IsMigrated() throws {
    let codec = SessionStoreCodec()
    let v10 = String(
      decoding: try codec.encode(sessions: [session("A"), session("B")]), as: UTF8.self)
    #expect(v10.contains(#""schemaVersion" : 10"#))
    let v9 = v10.replacingOccurrences(of: #""schemaVersion" : 10"#, with: #""schemaVersion" : 9"#)

    let decoded = try codec.decode(Data(v9.utf8))

    #expect(decoded.requiresRewrite)
    #expect(decoded.sessions.map(\.coordination) == [nil, nil])
  }

  @Test("A role written by a later build reads as an ordinary session instead of failing the store")
  func unknownRoleIsIgnored() throws {
    let codec = SessionStoreCodec()
    let text = String(
      decoding: try codec.encode(sessions: [session("A", coordination: .coordinator)]),
      as: UTF8.self
    )
    .replacingOccurrences(of: #""role" : "coordinator""#, with: #""role" : "conductor""#)

    let decoded = try codec.decode(Data(text.utf8))

    #expect(decoded.sessions.map(\.coordination) == [nil])
  }

  @Test("A child said to be its own reads as an ordinary session")
  func selfChildIsIgnored() throws {
    let codec = SessionStoreCodec()
    let id = SessionID()
    let other = SessionID()
    let text = String(
      decoding: try codec.encode(sessions: [session("A", id: id, coordination: .child(of: other))]),
      as: UTF8.self
    )
    .replacingOccurrences(
      of: other.rawValue.uuidString, with: id.rawValue.uuidString)

    let decoded = try codec.decode(Data(text.utf8))

    #expect(decoded.sessions.map(\.coordination) == [nil])
  }

  @Test("A session cannot be validated as its own child")
  func selfChildIsInvalid() {
    let id = SessionID()
    #expect(throws: WorkSessionValidationError.selfCoordinated) {
      try session("A", id: id, coordination: .child(of: id)).validate()
    }
  }
}

@Suite("Keeping what coordinators did and asked for")
struct FileCoordinationStoreTests {
  private func directory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("coordination-\(UUID().uuidString)", isDirectory: true)
  }

  @Test("A child's trace keeps its last 200 entries, in order")
  func traceIsBounded() async {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = FileCoordinationStore(directory: folder)
    let child = SessionID()
    for index in 0..<205 {
      await store.append(
        CoordinationTraceEntry(
          date: Date(timeIntervalSince1970: TimeInterval(index)), coordinatorName: "V2",
          action: .messaged, detail: "\(index)"),
        to: child)
    }
    let trace = await FileCoordinationStore(directory: folder).trace(of: child)
    #expect(trace.count == 200)
    #expect(trace.first?.detail == "5")
    #expect(trace.last?.detail == "204")
  }

  @Test("Wake-ups are kept across a relaunch, and taken away one by one")
  func wakes() async {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = FileCoordinationStore(directory: folder)
    let first = SessionID()
    let second = SessionID()
    let wake = CoordinationWake(date: Date(timeIntervalSince1970: 1_000), reason: "check #351")
    await store.setWake(wake, for: first)
    await store.setWake(CoordinationWake(date: Date(), reason: "x"), for: second)
    await store.setWake(nil, for: second)
    #expect(await FileCoordinationStore(directory: folder).wakes() == [first: wake])
  }

  @Test("An unreadable document is an empty one")
  func unreadable() async throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("{".utf8).write(to: folder.appendingPathComponent("wakes.json"))
    #expect(await FileCoordinationStore(directory: folder).wakes().isEmpty)
  }
}
