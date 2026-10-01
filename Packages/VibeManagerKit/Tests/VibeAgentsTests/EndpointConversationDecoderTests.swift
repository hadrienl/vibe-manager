import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

@Suite("An endpoint session's conversation")
struct EndpointConversationDecoderTests {
  private final class Fixed: ConversationDecoding {
    var entries: [ConversationEntry]
    init(_ entries: [ConversationEntry]) { self.entries = entries }
    func consume(_ record: TranscriptRecord) {}
  }

  private func text(_ id: String, at seconds: TimeInterval?) -> ConversationEntry {
    ConversationEntry(
      id: id, date: seconds.map { Date(timeIntervalSince1970: $0) }, content: .agentText(id))
  }

  @Test("The gateway's records are put in their place among the transcript's entries")
  func merges() throws {
    let journal = FileManager.default.temporaryDirectory
      .appendingPathComponent("steps-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: journal) }
    let records = [
      GatewayStepRecord(
        date: Date(timeIntervalSince1970: 15), kind: .step, name: "search_docs",
        input: #"{"q":"linear"}"#, output: "A-12"),
      GatewayStepRecord(
        date: Date(timeIntervalSince1970: 25), kind: .retry, attempt: 2, maximum: 5,
        delaySeconds: 11.2, failure: "rateLimited", status: 429),
      GatewayStepRecord(date: Date(timeIntervalSince1970: 99), kind: .step, name: "late"),
    ]
    var data = Data()
    for record in records {
      data += try GatewayStepRecord.encoder.encode(record) + Data("\n".utf8)
    }
    try data.write(to: journal)
    let decoder = EndpointConversationDecoder(
      inner: Fixed([text("a", at: 10), text("b", at: nil), text("c", at: 20), text("d", at: 30)]),
      journal: journal)

    let entries = decoder.entries
    #expect(entries.map(\.id) == ["a", "b", "gateway:0", "c", "gateway:1", "d", "gateway:2"])
    guard case .tool(let call) = entries[2].content else {
      Issue.record("a step is a tool call")
      return
    }
    #expect(call.kind == .mcp(server: "server", tool: "search_docs"))
    #expect(call.state == .succeeded)
    #expect(call.output?.text == "A-12")
    guard case .notice(.information(let sentence)) = entries[4].content else {
      Issue.record("a retry is a notice")
      return
    }
    #expect(sentence.contains("2") && sentence.contains("5") && sentence.contains("12"))
  }

  @Test("Without a journal, the transcript is shown as it is")
  func noJournal() {
    let decoder = EndpointConversationDecoder(
      inner: Fixed([text("a", at: 1)]),
      journal: URL(fileURLWithPath: "/nonexistent/steps.jsonl"))
    #expect(decoder.entries.map(\.id) == ["a"])
  }
}
