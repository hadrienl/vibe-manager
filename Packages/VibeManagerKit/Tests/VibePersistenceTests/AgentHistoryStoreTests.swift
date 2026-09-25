import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("Keeping the history of agent switches in the store")
struct AgentHistoryStoreTests {
  private let createdAt = Date(timeIntervalSince1970: 1_790_000_000)

  private func makeStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeManagerAgentHistory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("sessions.json")
  }

  private let v2Document = """
    {
      "schemaVersion": 2,
      "savedAt": "2026-09-21T10:00:00.000Z",
      "sessions": [
        {
          "id": "88E8C16B-2824-4CCC-8EF4-C7A1C16EA3AD",
          "name": "Stored in v2",
          "initialPrompt": "",
          "agent": { "providerID": "codex", "resumeIdentifier": "thread-123" },
          "appearance": { "symbolName": "terminal", "colorHex": "#5E5CE6" },
          "lifecycle": {
            "status": "closed",
            "createdAt": "2026-09-21T09:00:00.000Z",
            "updatedAt": "2026-09-21T10:00:00.000Z",
            "closedAt": "2026-09-21T10:00:00.000Z"
          },
          "repositories": []
        }
      ]
    }
    """

  @Test("A v2 session is read with an empty history, and the document is rewritten as v4")
  func v2IsMigrated() async throws {
    let storeURL = try makeStoreURL()
    defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
    try Data(v2Document.utf8).write(to: storeURL)
    let repository = FileSessionRepository(storeURL: storeURL)

    let session = try #require(try await repository.sessions().first)
    #expect(session.agentHistory.isEmpty)
    #expect(session.agent?.resumeIdentifier == "thread-123")

    let rewritten = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any]
    )
    #expect(rewritten["schemaVersion"] as? Int == 4)
  }

  @Test("Every switch comes back as it was written, a failed one included")
  func historyRoundTrips() throws {
    var session = WorkSession(
      name: "Audit deps",
      agent: SessionAgentConfiguration(
        providerID: "claude-code", modelID: "opus", resumeIdentifier: "claude-1"),
      createdAt: createdAt,
      updatedAt: createdAt,
      startedAt: createdAt
    )
    try session.switchAgent(
      to: SessionAgentConfiguration(providerID: "claude-code", modelID: "sonnet"),
      handover: .resumedConversation,
      at: createdAt.addingTimeInterval(10)
    )
    try session.switchAgent(
      to: SessionAgentConfiguration(providerID: "codex", modelID: "gpt-5.5"),
      handover: .summary(byteCount: 3_210, isTruncated: true, wasEdited: true),
      at: createdAt.addingTimeInterval(20)
    )
    let failed = try session.switchAgent(
      to: SessionAgentConfiguration(providerID: "mock"),
      handover: .nothing,
      at: createdAt.addingTimeInterval(30)
    )
    try session.revertAgentSwitch(failed.id, reason: "Mock Agent could not be started.")

    let codec = SessionStoreCodec()
    let decoded = try codec.decode(try codec.encode(sessions: [session]))

    #expect(decoded.requiresRewrite == false)
    #expect(decoded.sessions == [session])
  }

  @Test("A kind written by a later build does not take the store down")
  func unknownKindsAreReadAsTheClosestKnownOne() throws {
    let document = """
      {
        "schemaVersion": 4,
        "savedAt": "2026-09-21T10:00:00.000Z",
        "sessions": [
          {
            "id": "88E8C16B-2824-4CCC-8EF4-C7A1C16EA3AD",
            "name": "Written later",
            "initialPrompt": "",
            "agent": { "providerID": "codex" },
            "appearance": { "symbolName": "terminal", "colorHex": "#5E5CE6" },
            "lifecycle": {
              "status": "closed",
              "createdAt": "2026-09-21T09:00:00.000Z",
              "updatedAt": "2026-09-21T10:00:00.000Z",
              "closedAt": "2026-09-21T10:00:00.000Z"
            },
            "repositories": [],
            "agentHistory": [
              {
                "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
                "date": "2026-09-21T09:30:00.000Z",
                "previous": { "providerID": "claude-code" },
                "next": { "providerID": "codex" },
                "handover": "telepathy",
                "outcome": "postponed"
              }
            ]
          }
        ]
      }
      """

    let decoded = try SessionStoreCodec().decode(Data(document.utf8))

    let change = try #require(decoded.sessions.first?.agentHistory.first)
    #expect(change.handover == .nothing)
    #expect(change.outcome == .failed(reason: ""))
  }

  @Test("A document from a later schema is refused rather than rewritten without what it holds")
  func laterSchemaIsRefused() throws {
    let document = v2Document.replacingOccurrences(
      of: "\"schemaVersion\": 2", with: "\"schemaVersion\": 5")

    #expect(throws: SessionStoreCodecError.unsupportedSchemaVersion(5)) {
      try SessionStoreCodec().decode(Data(document.utf8))
    }
  }
}

@Suite("Keeping a session's ticket in the store")
struct SessionTicketStoreTests {
  @Test("A ticket comes back as it was written, a removed one included, and v4 reads as none")
  func roundTrip() throws {
    let codec = SessionStoreCodec()
    let sessions = [
      WorkSession(
        name: "A",
        ticket: SessionTicket(
          url: URL(string: "https://github.com/o/r/issues/1")!, source: .template)),
      WorkSession(name: "B", ticket: .removed),
      WorkSession(name: "C"),
    ]
    let data = try codec.encode(sessions: sessions)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains(#""schemaVersion" : 5"#))
    let decoded = try codec.decode(data)
    #expect(decoded.sessions.map(\.ticket) == sessions.map(\.ticket))
    #expect(!decoded.requiresRewrite)

    let v4 = text.replacingOccurrences(of: #""schemaVersion" : 5"#, with: #""schemaVersion" : 4"#)
    let old = try codec.decode(Data(v4.utf8))
    #expect(old.requiresRewrite)
    #expect(old.sessions.count == 3)
  }
}
