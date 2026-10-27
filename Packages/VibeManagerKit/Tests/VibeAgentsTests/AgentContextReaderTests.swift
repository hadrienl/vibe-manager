import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

@Suite("Reading the context window from transcripts")
struct AgentContextReaderTests {
  private func home() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeManagerContextReader-\(UUID().uuidString)", isDirectory: true)
  }

  private func write(_ lines: [String], to url: URL, append: Bool = false) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    if append, let handle = try? FileHandle(forWritingTo: url) {
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.close()
    } else {
      try data.write(to: url)
    }
  }

  private func reader(_ root: URL) -> AgentUsageReader {
    AgentUsageReader(
      locator: AgentTranscriptLocator(
        claudeProjects: root.appendingPathComponent("projects"),
        codexSessions: root.appendingPathComponent("sessions")),
      now: { Date(timeIntervalSince1970: 1_790_000_000) })
  }

  private func claudeAnswer(
    input: Int, cacheRead: Int, cacheWrite: Int, model: String = "claude-opus-5-5",
    sidechain: Bool = false, at timestamp: String = "2026-10-27T09:00:00.000Z"
  ) -> String {
    """
    {"type":"assistant","isSidechain":\(sidechain),"timestamp":"\(timestamp)",\
    "message":{"id":"m","model":"\(model)","content":[{"type":"text","text":"secret"}],\
    "usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(cacheWrite),\
    "cache_read_input_tokens":\(cacheRead),"output_tokens":50}}}
    """
  }

  private func codexCount(last: Int, window: Int?) -> String {
    let windowField = window.map { #","model_context_window":\#($0)"# } ?? ""
    return """
      {"timestamp":"2026-10-27T09:00:00.000Z","type":"event_msg","payload":{"type":"token_count",\
      "info":{"total_token_usage":{"input_tokens":1,"total_tokens":1},"last_token_usage":\
      {"input_tokens":\(last - 10),"cached_input_tokens":5,"output_tokens":10,\
      "total_tokens":\(last)}\(windowField)}}}
      """
  }

  @Test("Claude Code: the last main answer, with its cache; sub-agents and the CLI's own left out")
  func claudeLastMainAnswer() async throws {
    let root = home()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased()
    let session = WorkSession(
      name: "C", agent: SessionAgentConfiguration(providerID: "claude-code", resumeIdentifier: id))
    try write(
      [
        claudeAnswer(input: 10, cacheRead: 90_000, cacheWrite: 2_000),
        claudeAnswer(input: 1, cacheRead: 5, cacheWrite: 5, sidechain: true),
        claudeAnswer(input: 0, cacheRead: 0, cacheWrite: 0, model: "<synthetic>"),
      ], to: root.appendingPathComponent("projects/-repo/\(id).jsonl"))

    let file = await reader(root).readContext(of: session.agent!, session: session, from: nil)

    let usage = try #require(file?.usage)
    #expect(usage.usedTokens == 92_010)
    #expect(usage.windowSize == nil)
    #expect(usage.percentUsed == nil)
  }

  @Test("Claude Code: a compaction is said, and the next answer carries it")
  func claudeCompaction() async throws {
    let root = home()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased()
    let session = WorkSession(
      name: "C", agent: SessionAgentConfiguration(providerID: "claude-code", resumeIdentifier: id))
    let url = root.appendingPathComponent("projects/-repo/\(id).jsonl")
    try write([claudeAnswer(input: 1, cacheRead: 182_000, cacheWrite: 0)], to: url)
    let reader = reader(root)
    var file = await reader.readContext(of: session.agent!, session: session, from: nil)

    try write(
      [
        #"{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-10-27T09:10:00.000Z","compactMetadata":{"trigger":"auto","preTokens":182001}}"#
      ], to: url, append: true)
    file = await reader.readContext(of: session.agent!, session: session, from: file)
    #expect(file?.compaction?.tokensBefore == 182_001)
    #expect(file?.usage?.usedTokens == 182_001)

    try write(
      [claudeAnswer(input: 1, cacheRead: 31_000, cacheWrite: 0, at: "2026-10-27T09:11:00.000Z")],
      to: url, append: true)
    file = await reader.readContext(of: session.agent!, session: session, from: file)
    #expect(file?.usage?.usedTokens == 31_001)
    #expect(file?.usage?.lastCompaction?.tokensBefore == 182_001)
    #expect(file?.compaction == nil)
  }

  @Test("Codex: the context and window of the last count, with and without a window")
  func codexCounts() async throws {
    let root = home()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = "019e-test"
    let session = WorkSession(
      name: "X", agent: SessionAgentConfiguration(providerID: "codex", resumeIdentifier: id),
      createdAt: Date(timeIntervalSince1970: 1_790_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let parts = calendar.dateComponents([.year, .month, .day], from: session.createdAt)
    let url = root.appendingPathComponent(
      String(format: "sessions/%04d/%02d/%02d/rollout-x-\(id).jsonl", parts.year!, parts.month!,
        parts.day!))
    try write([codexCount(last: 22_556, window: nil)], to: url)
    let reader = reader(root)
    var file = await reader.readContext(of: session.agent!, session: session, from: nil)
    #expect(file?.usage?.usedTokens == 22_556)
    #expect(file?.usage?.windowSize == nil)

    try write(
      [
        codexCount(last: 100_000, window: 272_000),
        #"{"timestamp":"2026-10-27T09:20:00.000Z","type":"compacted","payload":{"message":"","replacement_history":[{"type":"message","content":[{"type":"input_text","text":"secret"}]}]}}"#,
        codexCount(last: 20_000, window: 272_000),
      ], to: url, append: true)
    file = await reader.readContext(of: session.agent!, session: session, from: file)
    let usage = try #require(file?.usage)
    #expect(usage.usedTokens == 20_000)
    #expect(usage.windowSize == 272_000)
    #expect(usage.source == .reportedByCLI)
    #expect(usage.lastCompaction?.tokensBefore == 100_000)
  }

  @Test("An agent that writes no transcript the application reads has no context")
  func otherAgent() async {
    let session = WorkSession(
      name: "M", agent: SessionAgentConfiguration(providerID: "mock", resumeIdentifier: "x"))
    #expect(await reader(home()).readContext(of: session.agent!, session: session, from: nil) == nil)
  }

  @Test("The decoded context lines declare no content field")
  func decodedTypesHoldNoContent() throws {
    let claude = try JSONDecoder().decode(
      ClaudeContextLine.self,
      from: Data(claudeAnswer(input: 1, cacheRead: 1, cacheWrite: 1).utf8))
    #expect(
      Set(Mirror(reflecting: claude).children.compactMap(\.label))
        == ["type", "subtype", "timestamp", "isSidechain", "message", "compactMetadata"])
    #expect(
      Set(Mirror(reflecting: try #require(claude.message)).children.compactMap(\.label))
        == ["model", "usage"])
    let compacted = try JSONDecoder().decode(
      CodexContextLine.self,
      from: Data(#"{"type":"compacted","payload":{"type":"x","message":"secret"}}"#.utf8))
    #expect(compacted.payload == nil)
    let info = try JSONDecoder().decode(
      CodexUsageLine.Info.self, from: Data(#"{"model_context_window":1,"text":"secret"}"#.utf8))
    #expect(
      Set(Mirror(reflecting: info).children.compactMap(\.label))
        == ["lastTokenUsage", "totalTokenUsage", "modelContextWindow"])
  }
}

@Suite("The share of the context window")
struct ContextWindowUsageTests {
  @Test("A plain share, rounded, never above 100")
  func plainShare() {
    let date = Date()
    #expect(ContextWindowUsage(usedTokens: 92_000, windowSize: 200_000, measuredAt: date).percentUsed == 46)
    #expect(ContextWindowUsage(usedTokens: 300_000, windowSize: 200_000, measuredAt: date).percentUsed == 100)
    #expect(ContextWindowUsage(usedTokens: 92_000, measuredAt: date).percentUsed == nil)
  }

  @Test("Codex: its baseline out of both, as its own “context left”")
  func codexShare() {
    let usage = ContextWindowUsage(
      usedTokens: 22_556, windowSize: 475_000, measuredAt: Date(), countsLikeCodex: true)
    // (22 556 − 12 000) / (475 000 − 12 000) = 2.3 % used: Codex says 98 % left.
    #expect(usage.percentUsed == 2)
    let fresh = ContextWindowUsage(
      usedTokens: 9_000, windowSize: 475_000, measuredAt: Date(), countsLikeCodex: true)
    #expect(fresh.percentUsed == 0)
  }

  @Test("The endpoint's window wins over the CLI's")
  func endpointWins() {
    let usage = ContextWindowUsage(
      usedTokens: 50_000, windowSize: 475_000, measuredAt: Date(), source: .reportedByCLI,
      countsLikeCodex: true
    ).declared(by: "Local", window: 100_000)
    #expect(usage.windowSize == 100_000)
    #expect(usage.source == .declaredByEndpoint("Local"))
    #expect(usage.percentUsed == 50)
    let undeclared = ContextWindowUsage(usedTokens: 1, measuredAt: Date())
      .declared(by: "Local", window: nil)
    #expect(undeclared.windowSize == nil)
  }
}
