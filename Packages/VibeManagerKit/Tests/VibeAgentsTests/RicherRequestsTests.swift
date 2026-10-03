import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

private func event(_ name: String, _ payload: String) -> AgentActivityEvent {
  AgentActivityEvent(name: name, date: Date(), payload: Data(payload.utf8))
}

private func notice(of signal: AgentSignal?) -> AgentRequestNotice? {
  guard case .questionAsked(_, _, let notice) = signal else { return nil }
  return notice
}

@Suite("An MCP server's elicitation, as Claude Code reports it (#273, P3)")
struct ElicitationReadingTests {
  /// What the documentation's example hands the hook, through the hook's own command.
  private func reported(mode: String, url: String) throws -> AgentActivityEvent {
    let log = try temporaryLog()
    let hook = try #require(
      ClaudeCodeActivityHooks.hooks.first { $0.event == "Elicitation" })
    _ = try runHook(
      AgentActivityHookCommand.command(event: hook.event, payload: hook.payload),
      input: """
        {"session_id":"abc","hook_event_name":"Elicitation","mcp_server_name":"memory",\
        "tool_name":"mcp__memory__create","message":"Please sign in",\
        "mode":"\(mode)","requested_schema":{"type":"object","properties":{"url":{"type":"string"}}},\
        "url":"\(url)","elicitation_id":"e1"}
        """,
      log: log)
    let line = try #require(lines(of: log).first)
    return event(line[0], line[2])
  }

  private func elicitation(_ event: AgentActivityEvent) -> AgentElicitation? {
    guard case .elicitation(let elicitation) = notice(of: ClaudeCodeSignalDecoder().signal(for: event))?
      .content
    else { return nil }
    return elicitation
  }

  @Test("A page to open keeps the server, its words and the address")
  func url() throws {
    let read = try #require(elicitation(try reported(mode: "url", url: "https://example.org/a?b=1")))
    #expect(read.server == "memory")
    #expect(read.message == "Please sign in")
    #expect(read.url == URL(string: "https://example.org/a?b=1"))
  }

  @Test("A form gives no page, even when an address comes with it")
  func form() throws {
    let read = try #require(elicitation(try reported(mode: "form", url: "https://example.org")))
    #expect(read.message == "Please sign in")
    #expect(read.url == nil)
  }

  @Test("Only a web page is ever opened")
  func schemes() {
    #expect(AgentElicitation(url: URL(string: "file:///etc/passwd")).url == nil)
    #expect(AgentElicitation(url: URL(string: "javascript:alert(1)")).url == nil)
    #expect(AgentElicitation(url: URL(string: "HTTP://example.org")).url != nil)
  }
}

@Suite("A plan past the hook's byte limit (#273, P3)")
struct LongPlanReadingTests {
  @Test("Its beginning is read from the cut report, never as complete")
  func cut() throws {
    let steps = (1...2000).map { "- Step \($0): do \"this\" then that" }
    // In Claude Code's order (2.1.288): the tool's name first, the plan, then its file.
    let plan = try JSONSerialization.data(
      withJSONObject: steps.joined(separator: "\n"), options: .fragmentsAllowed)
    let input =
      #"{"session_id":"s","permission_mode":"plan","hook_event_name":"PermissionRequest","#
      + #""tool_name":"ExitPlanMode","tool_input":{"plan":"# + String(decoding: plan, as: UTF8.self)
      + #","planFilePath":"/Users/a/.claude/plans/p.md"}}"#
    let log = try temporaryLog()
    _ = try runHook(
      AgentActivityHookCommand.command(event: "PermissionRequest", payload: .keep),
      input: input, log: log)
    let line = try #require(lines(of: log).first)
    let signal = ClaudeCodeSignalDecoder().signal(for: event(line[0], line[2]))
    guard case .plan(let excerpt, let isComplete) = notice(of: signal)?.content else {
      Issue.record("not read as a plan: \(String(describing: signal))")
      return
    }
    #expect(!isComplete)
    #expect(
      excerpt
        == steps.prefix(AgentRequestReading.planExcerptLineLimit).joined(separator: "\n"))
  }

  @Test("An escape the cut split is left out; whole ones are kept")
  func splitEscapes() {
    func read(_ cut: String) -> String? {
      AgentRequestReading.leadingString("plan", in: #"{"tool_input":{"plan":""# + cut)
    }
    #expect(read(#"a\"b\"#) == #"a"b"#)
    #expect(read(#"a\\"#) == #"a\"#)
    #expect(read(#"a\\\"#) == #"a\"#)
    #expect(read(#"a\u00"#) == "a")
    #expect(read(#"a\u00e9"#) == "aé")
    #expect(read(#"a\ud83d"#) == "a")
    #expect(read(#"a\ud83d\ude00"#) == "a😀")
    #expect(read(#"a\ud83d\ude"#) == "a")
    #expect(AgentRequestReading.leadingString("plan", in: #"{"permission_mode":"plan"}"#) == nil)
  }
}

@Suite("Codex's asynchronous questions, read from its rollout (#273, P3)")
struct AsyncQuestionWatchTests {
  /// As `core/src/tools/handlers/request_user_input_async.rs` (0.159.2) takes them.
  static let call =
    #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input_async","arguments":"{\"questions\":[{\"title\":\"Which port?\",\"options\":[\"8080\",\"3000\"]},{\"title\":\"Any name?\"}]}","call_id":"call_a"}}"#
  static let accepted =
    #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_a","output":"{\"accepted\":true}"}}"#
  static let turnComplete = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t"}}"#

  @Test("Asked with its titles and suggested answers; taken, not answered; gone with the turn")
  func lifecycle() throws {
    var pending: Set<String> = []
    let asked = CodexQuestionWatch.signals(in: Data(Self.call.utf8), pending: &pending)
    let notice = try #require(notice(of: asked.first))
    #expect(notice.key == "codex:call_a")
    #expect(notice.reference == AgentToolReference(tool: "request_user_input_async", subject: "call_a"))
    #expect(
      notice.content
        == .questions([
          AgentQuestion(header: nil, text: "Which port?", options: [.init(label: "8080"), .init(label: "3000")]),
          AgentQuestion(header: nil, text: "Any name?", options: []),
        ]))
    #expect(CodexQuestionWatch.signals(in: Data(Self.accepted.utf8), pending: &pending).isEmpty)
    #expect(
      CodexQuestionWatch.signals(in: Data(Self.turnComplete.utf8), pending: &pending)
        == [.toolFinished("request_user_input_async", subject: "call_a")])
    #expect(pending.isEmpty)
  }

  @Test("A turn's end leaves a waiting request_user_input alone")
  func syncStays() {
    var pending: Set<String> = []
    _ = CodexQuestionWatch.signals(
      in: Data(RequestPayloads.codexQuestionCall.utf8), pending: &pending)
    #expect(CodexQuestionWatch.signals(in: Data(Self.turnComplete.utf8), pending: &pending).isEmpty)
    #expect(pending == ["call_1"])
  }

  @Test("Of a rollout's history, only the question of the turn still running is said")
  func history() throws {
    let rollout = FileManager.default.temporaryDirectory.appendingPathComponent(
      "async-\(UUID().uuidString).jsonl")
    let later = Self.call.replacingOccurrences(of: "call_a", with: "call_b")
    try Data(([Self.call, Self.accepted, Self.turnComplete, later].joined(separator: "\n") + "\n").utf8)
      .write(to: rollout)
    let (pending, waiting, _) = CodexQuestionWatch.unanswered(in: rollout)
    #expect(pending == ["async:call_b"])
    #expect(waiting.compactMap { notice(of: $0)?.key } == ["codex:call_b"])
  }
}
