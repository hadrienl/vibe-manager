import Foundation
import Testing
import VibeDomain

@testable import VibePersistence

@Suite("Keeping the history of a session's statuses in the store (#406)")
struct SessionStatusHistoryStoreTests {
  let start = Date(timeIntervalSince1970: 1_700_000_000)

  private func moved() throws -> WorkSession {
    let coordinator = SessionID()
    var session = WorkSession(
      name: "A", status: .closed, createdAt: start, updatedAt: start, closedAt: start,
      statusHistory: .created(in: .todo, at: start), infersStartedAt: false)
    try session.setTaskStatus(.doing, at: start.addingTimeInterval(1), cause: .launch)
    try session.setTaskStatus(
      .waiting, at: start.addingTimeInterval(2), cause: .coordinator(coordinator))
    try session.setTaskStatus(.done, at: start.addingTimeInterval(3), cause: .user)
    try session.archive(
      at: start.addingTimeInterval(4), cause: .rule(id: UUID(), name: "Rouges, le 15"))
    try session.restore(at: start.addingTimeInterval(5), cause: .unarchive)
    try session.archive(at: start.addingTimeInterval(6), cause: .user)
    try session.restore(at: start.addingTimeInterval(7), cause: .undo)
    return session
  }

  @Test("A v11 store gives back every entry and every cause")
  func roundTrip() throws {
    let codec = SessionStoreCodec()
    let session = try moved()
    let data = try codec.encode(sessions: [session])
    #expect(String(decoding: data, as: UTF8.self).contains(#""schemaVersion" : 11"#))

    let decoded = try codec.decode(data)

    #expect(!decoded.requiresRewrite)
    #expect(decoded.sessions.first?.statusHistory == session.statusHistory)
  }

  @Test("A v10 store is given a history rebuilt from the lifecycle, and rewritten")
  func v10IsMigrated() throws {
    let codec = SessionStoreCodec()
    let session = WorkSession(
      name: "Old", status: .closed, createdAt: start, updatedAt: start.addingTimeInterval(50),
      startedAt: start.addingTimeInterval(10), taskStatus: .done)
    var object = try #require(
      try JSONSerialization.jsonObject(with: codec.encode(sessions: [session]))
        as? [String: Any])
    object["schemaVersion"] = 10
    var sessions = try #require(object["sessions"] as? [[String: Any]])
    sessions[0]["statusHistory"] = nil
    object["sessions"] = sessions

    let decoded = try codec.decode(try JSONSerialization.data(withJSONObject: object))

    #expect(decoded.requiresRewrite)
    let history = try #require(decoded.sessions.first?.statusHistory)
    #expect(history.entries.map(\.to) == [.todo, .doing, .done])
    #expect(history.entries.allSatisfy { $0.cause == .reconstructed })
  }

  @Test("A cause written by a later build rebuilds the history instead of failing the store")
  func unknownCauseRebuilds() throws {
    let codec = SessionStoreCodec()
    let text = String(decoding: try codec.encode(sessions: [try moved()]), as: UTF8.self)
      .replacingOccurrences(of: #""cause" : "launch""#, with: #""cause" : "schedule""#)

    let decoded = try codec.decode(Data(text.utf8))

    let history = try #require(decoded.sessions.first?.statusHistory)
    #expect(history.entries.allSatisfy { $0.cause == .reconstructed })
    #expect(history.lastEntry?.to == .done)
  }

  @Test("A history edited until it no longer leads to the status is rebuilt")
  func brokenChainRebuilds() throws {
    let codec = SessionStoreCodec()
    let text = String(decoding: try codec.encode(sessions: [try moved()]), as: UTF8.self)
      .replacingOccurrences(of: #""to" : "waiting""#, with: #""to" : "todo""#)

    let decoded = try codec.decode(Data(text.utf8))

    #expect(
      decoded.sessions.first?.statusHistory.entries.allSatisfy { $0.cause == .reconstructed }
        == true)
  }
}
