import Foundation
import Testing

@testable import VibeDomain

@Suite("The journal of a session")
struct SessionJournalTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func resource(
    _ key: String, _ kind: SessionResource.Kind = .issue, label: String = "#1",
    _ involvement: SessionResource.Involvement = .viewed, at offset: TimeInterval = 0
  ) -> SessionResource {
    SessionResource(
      key: key, kind: kind, label: label, context: "o/r",
      target: .web(URL(string: "https://github.com/o/r/issues/1")!), involvement: involvement,
      firstSeenAt: start.addingTimeInterval(offset))
  }

  @Test("Resources are kept once, in the order they were first seen")
  func deduplication() {
    var journal = SessionJournal()
    journal.record([resource("a"), resource("b"), resource("a", at: 60)])
    #expect(journal.resources.map(\.key) == ["a", "b"])
    #expect(journal.resources[0].firstSeenAt == start)
    #expect(journal.resources[0].lastSeenAt == start.addingTimeInterval(60))
  }

  @Test("Involvement only ever rises: a request created then viewed stays created")
  func involvementRises() {
    var journal = SessionJournal()
    journal.record([resource("a", .pullRequest, .created)])
    journal.record([resource("a", .pullRequest, .viewed)])
    #expect(journal.resources.first?.involvement == .created)
  }

  @Test("On GitHub, a number first seen as an issue that is a pull request becomes one")
  func pullRequestWins() {
    var journal = SessionJournal()
    journal.record([resource("github:x#62", .issue, label: "#62")])
    var request = resource("github:x#62", .pullRequest, label: "#62")
    request.target = .web(URL(string: "https://github.com/o/r/pull/62")!)
    journal.record([request])
    #expect(journal.resources.first?.kind == .pullRequest)
    #expect(journal.resources.first?.target == request.target)
  }

  @Test("Past the bound, resources are counted, not kept")
  func resourceBound() {
    var journal = SessionJournal()
    journal.record((0...SessionJournal.resourceLimit).map { resource("k\($0)") })
    #expect(journal.resources.count == SessionJournal.resourceLimit)
    #expect(journal.overflowResourceCount == 1)
  }

  @Test("Past the bound, the oldest entries fold into one that says how many")
  func entryBound() {
    var journal = SessionJournal()
    journal.append(
      (0..<(SessionJournal.entryLimit + 10)).map {
        JournalEntry(text: "e\($0)", at: start.addingTimeInterval(Double($0)), providerID: nil)
      })
    #expect(journal.entries.count == SessionJournal.entryLimit)
    #expect(journal.entries.first?.foldedCount == 11)
    #expect(journal.entries.last?.text == "e\(SessionJournal.entryLimit + 9)")
    journal.append([JournalEntry(text: "more", at: start, providerID: nil)])
    #expect(journal.entries.first?.foldedCount == 12)
  }

  @Test("A turn ends once, and only a turn in which something happened")
  func turns() {
    var journal = SessionJournal()
    journal.endTurn(at: start)
    #expect(!journal.hasEndedTurn)
    journal.withOpenTurn(providerID: "claude-code") { $0.prompts.append("fix it") }
    journal.withOpenTurn(providerID: "claude-code") { $0.actions.append("Bash: swift test") }
    journal.endTurn(at: start)
    journal.endTurn(at: start.addingTimeInterval(5))
    #expect(journal.pending.count == 1)
    #expect(journal.pending[0].endedAt == start)
    journal.withOpenTurn(providerID: "claude-code") { $0.prompts.append("push") }
    #expect(journal.endedTurns.count == 1)
    journal.summarized([journal.pending[0].id], at: start)
    #expect(journal.pending.map(\.prompts) == [["push"]])
    #expect(journal.hasEndedTurn)
  }

  @Test("A pass removes the turns it summarized, not those that came or went meanwhile")
  func summarizedByIdentity() {
    var journal = SessionJournal()
    journal.withOpenTurn(providerID: nil) { $0.prompts.append("one") }
    journal.endTurn(at: start)
    let summarizing = Set(journal.endedTurns.map(\.id))
    for index in 0..<SessionJournal.pendingTurnLimit {
      journal.withOpenTurn(providerID: nil) { $0.prompts.append("later \(index)") }
      journal.endTurn(at: start)
    }
    journal.summarized(summarizing, at: start)
    #expect(journal.pending.count == SessionJournal.pendingTurnLimit)
    #expect(journal.pending.first?.prompts == ["later 0"])
  }

  @Test("A journal survives a round trip through JSON")
  func codable() throws {
    var journal = SessionJournal()
    journal.record([resource("a", .branch, label: "x")])
    journal.resources[0].target = .branch(repositoryPath: "/r", webURL: nil)
    journal.append([JournalEntry(text: "Pushed", at: start, providerID: "codex")])
    journal.summary = .failed(at: start, attempts: 2)
    journal.cursors["/t.jsonl"] = TranscriptCursor(offset: 12, inode: 3)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SessionJournal.self, from: encoder.encode(journal))
    #expect(decoded == journal)
  }
}
