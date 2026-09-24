import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

@Suite("Reading token usage from transcripts")
struct AgentUsageReaderTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private func home() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeManagerUsageReader-\(UUID().uuidString)", isDirectory: true)
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

  private func claudeSession(_ identifier: String) -> WorkSession {
    WorkSession(
      name: "Claude",
      agent: SessionAgentConfiguration(providerID: "claude-code", resumeIdentifier: identifier))
  }

  private func codexSession(_ identifier: String, created: Date) -> WorkSession {
    WorkSession(
      name: "Codex",
      agent: SessionAgentConfiguration(providerID: "codex", resumeIdentifier: identifier),
      createdAt: created, updatedAt: created)
  }

  private func assistant(
    id: String, request: String, model: String = "claude-opus-5-5", input: Int, output: Int,
    at timestamp: String = "2026-09-24T09:00:00.000Z", text: String = "secret answer"
  ) -> String {
    """
    {"type":"assistant","timestamp":"\(timestamp)","requestId":"\(request)","message":{"id":"\(id)",\
    "model":"\(model)","content":[{"type":"text","text":"\(text)"}],"usage":{"input_tokens":\(input),\
    "cache_creation_input_tokens":7,"cache_read_input_tokens":100,"output_tokens":\(output)}}}
    """
  }

  private func reader(_ root: URL, now: Date = Date()) -> AgentUsageReader {
    AgentUsageReader(
      locator: AgentTranscriptLocator(
        claudeProjects: root.appendingPathComponent("projects"),
        codexSessions: root.appendingPathComponent("sessions")),
      calendar: calendar, now: { now })
  }

  @Test("An answer written over several lines is counted once, sub-agents added")
  func claudeDeduplicates() async throws {
    let root = home()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = UUID().uuidString.lowercased()
    let folder = root.appendingPathComponent("projects/-Users-me-repo")
    try write(
      [
        #"{"type":"user","message":{"role":"user","content":"please \"usage\": 999"}}"#,
        assistant(id: "msg_1", request: "req_1", input: 10, output: 5),
        assistant(id: "msg_1", request: "req_1", input: 10, output: 5),
        assistant(id: "msg_2", request: "req_2", input: 3, output: 2),
        assistant(id: "msg_3", request: "req_3", model: "<synthetic>", input: 0, output: 0),
      ], to: folder.appendingPathComponent("\(identifier).jsonl"))
    try write(
      [assistant(id: "msg_s", request: "req_s", model: "claude-haiku-4-5", input: 1, output: 1)],
      to: folder.appendingPathComponent("\(identifier)/subagents/agent-a.jsonl"))
    let session = claudeSession(identifier)

    let snapshot = await reader(root).refresh([session], from: .empty, isTracked: { _ in true })

    let buckets = snapshot.buckets
    let opus = buckets.first { $0.model == "claude-opus-5-5" }
    #expect(opus?.tokens.input == 13)
    #expect(opus?.tokens.output == 7)
    #expect(opus?.tokens.cacheRead == 200)
    #expect(opus?.tokens.cacheWrite == 14)
    #expect(opus?.responses == 2)
    #expect(buckets.first { $0.model == "claude-haiku-4-5" }?.responses == 1)
    #expect(!buckets.contains { $0.model == "<synthetic>" })
  }

  @Test("Reading goes on where it stopped, and a replaced file is read again")
  func incremental() async throws {
    let root = home()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = UUID().uuidString.lowercased()
    let url = root.appendingPathComponent("projects/-repo/\(identifier).jsonl")
    try write([assistant(id: "m1", request: "r1", input: 10, output: 1)], to: url)
    let session = claudeSession(identifier)
    let subject = reader(root)

    var snapshot = await subject.refresh([session], from: .empty, isTracked: { _ in true })
    try write([assistant(id: "m2", request: "r2", input: 5, output: 1)], to: url, append: true)
    // Half a line: the CLI is still writing it.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"type":"assistant","#.utf8))
    try handle.close()
    snapshot = await subject.refresh([session], from: snapshot, isTracked: { _ in true })
    #expect(snapshot.buckets.first?.tokens.input == 15)

    try FileManager.default.removeItem(at: url)
    try write([assistant(id: "m9", request: "r9", input: 1, output: 1)], to: url)
    snapshot = await subject.refresh([session], from: snapshot, isTracked: { _ in true })
    #expect(snapshot.buckets.first?.tokens.input == 1)
  }

  @Test("A transcript the CLI deleted keeps what it reported")
  func deletedTranscript() async throws {
    let root = home()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = UUID().uuidString.lowercased()
    let url = root.appendingPathComponent("projects/-repo/\(identifier).jsonl")
    try write([assistant(id: "m1", request: "r1", input: 10, output: 1)], to: url)
    let session = claudeSession(identifier)
    let subject = reader(root)
    var snapshot = await subject.refresh([session], from: .empty, isTracked: { _ in true })

    try FileManager.default.removeItem(at: url)
    snapshot = await subject.refresh([session], from: snapshot, isTracked: { _ in true })

    #expect(snapshot.buckets.first?.tokens.input == 10)
    #expect(snapshot.missingSince(for: session.id) != nil)
  }

  @Test("Usage from outside the tracking intervals is not counted")
  func untracked() async throws {
    let root = home()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = UUID().uuidString.lowercased()
    try write(
      [assistant(id: "m1", request: "r1", input: 10, output: 1)],
      to: root.appendingPathComponent("projects/-repo/\(identifier).jsonl"))

    let snapshot = await reader(root).refresh(
      [claudeSession(identifier)], from: .empty, isTracked: { _ in false })

    #expect(snapshot.buckets.isEmpty)
  }

  @Test("Codex: records by response, the model of the turn, cached input apart")
  func codexRecords() async throws {
    let root = home()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = "01a0cd8c-0224-7721-8fff-e7b7647eff14"
    let created = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 9))!
    let url = root.appendingPathComponent(
      "sessions/2026/09/23/rollout-2026-09-23T11-15-00-\(identifier).jsonl")
    let record = """
      {"timestamp":"2026-09-23T09:15:10.593Z","type":"token_usage_record","payload":{"response_id":"resp_1",\
      "usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":0,"output_tokens":10,\
      "reasoning_output_tokens":4,"total_tokens":110}}}
      """
    try write(
      [
        #"{"timestamp":"2026-09-23T09:15:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","cwd":"/repo"}}"#,
        #"{"timestamp":"2026-09-23T09:15:01.000Z","type":"response_item","payload":{"type":"message","content":"say \"token_usage_record\""}}"#,
        record, record,
        #"{"timestamp":"2026-09-23T09:15:11.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":10}}}}"#,
      ], to: url)

    let snapshot = await reader(root, now: created).refresh(
      [codexSession(identifier, created: created)], from: .empty, isTracked: { _ in true })

    let bucket = snapshot.buckets.first
    #expect(snapshot.buckets.count == 1)
    #expect(bucket?.model == "gpt-5.6-sol")
    #expect(bucket?.tokens.input == 40)
    #expect(bucket?.tokens.cacheRead == 60)
    #expect(bucket?.tokens.output == 10)
    #expect(bucket?.tokens.reasoning == 4)
    #expect(bucket?.responses == 1)
  }

  @Test("Codex: an older rollout without records is counted by turn")
  func codexFallback() async throws {
    let root = home()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = "01a0c58c-5860-7000-8000-000000000000"
    let created = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 21))!
    try write(
      [
        #"{"timestamp":"2026-09-21T21:58:30.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":5}}}}"#,
        #"{"timestamp":"2026-09-21T21:59:30.000Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
      ],
      to: root.appendingPathComponent(
        "sessions/2026/09/21/rollout-2026-09-21T21-58-24-\(identifier).jsonl"))

    let snapshot = await reader(root, now: created).refresh(
      [codexSession(identifier, created: created)], from: .empty, isTracked: { _ in true })

    #expect(snapshot.buckets.first?.tokens.input == 50)
    #expect(snapshot.buckets.first?.model == "unknown")
  }

  @Test("Codex: a per-turn event repeated with the same total is counted once")
  func codexFallbackRepeats() async throws {
    let root = home()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = "01a0c58c-5860-7000-8000-000000000001"
    let created = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 21))!
    let event = """
      {"timestamp":"2026-09-21T21:58:30.000Z","type":"event_msg","payload":{"type":"token_count",\
      "info":{"total_token_usage":{"input_tokens":50,"output_tokens":5},\
      "last_token_usage":{"input_tokens":50,"output_tokens":5}}}}
      """
    try write(
      [event, event],
      to: root.appendingPathComponent(
        "sessions/2026/09/21/rollout-2026-09-21T21-58-24-\(identifier).jsonl"))

    let snapshot = await reader(root, now: created).refresh(
      [codexSession(identifier, created: created)], from: .empty, isTracked: { _ in true })

    #expect(snapshot.buckets.first?.tokens.input == 50)
    #expect(snapshot.buckets.first?.responses == 1)
  }

  @Test("The totals are keyed by a digest, never by the path of the repository")
  func keysHideThePath() async throws {
    let root = home()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = UUID().uuidString.lowercased()
    try write(
      [assistant(id: "m1", request: "r1", input: 1, output: 1)],
      to: root.appendingPathComponent("projects/-Users-me-client-secret/\(identifier).jsonl"))

    let snapshot = await reader(root).refresh(
      [claudeSession(identifier)], from: .empty, isTracked: { _ in true })

    let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    #expect(!encoded.contains("client-secret"))
    #expect(snapshot.buckets.count == 1)
  }

  @Test("Nothing of what was said reaches the totals")
  func noContentIsKept() async throws {
    let root = home()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = UUID().uuidString.lowercased()
    try write(
      [assistant(id: "m1", request: "r1", input: 1, output: 1, text: "TOP-SECRET-PROMPT")],
      to: root.appendingPathComponent("projects/-repo/\(identifier).jsonl"))

    let snapshot = await reader(root).refresh(
      [claudeSession(identifier)], from: .empty, isTracked: { _ in true })

    let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    #expect(!encoded.contains("TOP-SECRET-PROMPT"))
  }

  @Test("The decoded lines declare no content field")
  func decodedTypesHoldNoContent() throws {
    let line = Data(assistant(id: "m1", request: "r1", input: 1, output: 1).utf8)
    let decoded = try JSONDecoder().decode(ClaudeUsageLine.self, from: line)
    #expect(
      Set(Mirror(reflecting: decoded).children.compactMap(\.label))
        == ["type", "timestamp", "requestId", "message"])
    let message = try #require(decoded.message)
    #expect(
      Set(Mirror(reflecting: message).children.compactMap(\.label)) == ["id", "model", "usage"])
    let codex = try JSONDecoder().decode(
      CodexUsageLine.Payload.self, from: Data(#"{"type":"x","content":"secret"}"#.utf8))
    #expect(
      Set(Mirror(reflecting: codex).children.compactMap(\.label))
        == ["type", "model", "responseID", "usage", "info"])
  }
}
