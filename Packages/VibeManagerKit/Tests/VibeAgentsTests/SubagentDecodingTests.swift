import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

/// Shaped after Claude Code 2.1.284–2.1.285 and Codex 0.157.1 transcripts, their words replaced:
/// nothing a user or an agent wrote is kept in the repository.
@Suite("Reading sub-agents from a Claude Code transcript")
struct ClaudeCodeSubagentTests {
  private func decode(_ lines: [String], subagent: Bool = false) -> [ConversationEntry] {
    let decoder =
      subagent
      ? ClaudeCodeConversationDecoder(subagentFile: URL(fileURLWithPath: "/s/agent-a1.jsonl"))
      : ClaudeCodeConversationDecoder()
    for line in lines { decoder.consume(Data(line.utf8)) }
    return decoder.entries
  }

  private let launch =
    #"{"type":"assistant","uuid":"a1","timestamp":"2026-09-29T13:34:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"description":"Review the diff","subagent_type":"general-purpose","prompt":"Read the diff and report."}}]}}"#
  private let launched =
    #"{"type":"user","uuid":"u1","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"Async agent launched successfully.\nagentId: a1"}]}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"a1","description":"Review the diff","prompt":"Read the diff and report."}}"#

  private func notification(
    _ status: String, result: String, summary: String = "Agent finished", agent: String = "a1",
    call: String = "t1"
  ) -> String {
    let text =
      "<task-notification>\n<task-id>\(agent)</task-id>\n<tool-use-id>\(call)</tool-use-id>\n<status>\(status)</status>\n<summary>\(summary)</summary>\n<result>\(result)</result>\n<usage><subagent_tokens>1200</subagent_tokens><tool_uses>29</tool_uses><duration_ms>260246</duration_ms></usage>\n</task-notification>"
    let object: [String: Any] = [
      "type": "user", "uuid": "n-\(status)-\(call)", "origin": ["kind": "task-notification"],
      "message": ["role": "user", "content": text],
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }

  private func call(_ entries: [ConversationEntry]) -> ToolCall? {
    entries.first { $0.id == "t1" }?.toolCall
  }

  @Test("Launched in the background: running, with its identifier, until its notification")
  func background() {
    let running = decode([launch, launched])
    #expect(call(running)?.kind == .subagent)
    #expect(call(running)?.state == .running)
    #expect(call(running)?.output == nil)
    #expect(call(running)?.subagent?.agentID == "a1")
    #expect(call(running)?.subagent?.mode == .background)
    #expect(call(running)?.subagent?.type == "general-purpose")
    #expect(call(running)?.subagent?.startedAt != nil)
    #expect(call(running)?.parameter(.prompt) == "Read the diff and report.")

    let done = decode([launch, launched, notification("completed", result: "All **good**.")])
    #expect(done.count == 1)
    #expect(call(done)?.state == .succeeded)
    #expect(call(done)?.subagent?.result == "All **good**.")
    #expect(call(done)?.subagent?.usage?.toolUses == 29)
    #expect(call(done)?.subagent?.usage?.duration == .milliseconds(260_246))
    #expect(call(done)?.subagent?.usage?.tokens == 1200)
  }

  @Test("Its answer handed back as a message, the notification only saying so")
  func handback() {
    let body =
      "[Subagent hand-back] The text below is the final report. The report follows:\n  # Findings\n  \n  - one\n  - two"
    let object: [String: Any] = [
      "type": "user", "uuid": "h", "isMeta": true,
      "origin": ["kind": "peer", "from": "a1", "body": body, "handback": true],
      "message": ["role": "user", "content": "Another Claude session sent a message:\n<agent-message from=\"a1\">…"],
    ]
    let line = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    let entries = decode([
      launch, launched, line,
      notification(
        "completed",
        result: "This agent's report was delivered to you as a message from \"a1\". Read it there."),
    ])
    #expect(entries.count == 1)
    #expect(call(entries)?.state == .succeeded)
    #expect(call(entries)?.subagent?.result == "# Findings\n\n- one\n- two")
  }

  @Test("Failed, killed or stopped: said so, with the reason of a failure")
  func endings() {
    let failed = decode([
      launch, launched,
      notification(
        "failed", result: "I'll start by reading.",
        summary: "Agent \"Review the diff\" failed: Agent terminated early due to an API error"),
    ])
    #expect(call(failed)?.state == .failed(exitCode: nil))
    #expect(call(failed)?.subagent?.failure == "Agent terminated early due to an API error")
    #expect(call(failed)?.subagent?.result == nil)
    for status in ["killed", "stopped"] {
      let ended = decode([launch, launched, notification(status, result: "")])
      #expect(call(ended)?.state == .interrupted)
    }
  }

  @Test("A notification may come as a queued command, and come again: the last word stands")
  func queuedAndRepeated() {
    let text = notification("completed", result: "First.")
    let object = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    let content = (object["message"] as! [String: Any])["content"] as! String
    let queued: [String: Any] = [
      "type": "attachment", "uuid": "q",
      "attachment": [
        "type": "queued_command", "commandMode": "task-notification", "prompt": content,
      ],
    ]
    let line = String(decoding: try! JSONSerialization.data(withJSONObject: queued), as: UTF8.self)
    let sendMessage =
      #"{"type":"assistant","uuid":"a2","message":{"content":[{"type":"tool_use","id":"t2","name":"SendMessage","input":{"to":"a1","message":"One more thing"}}]}}"#
    let entries = decode([launch, launched, line])
    #expect(call(entries)?.state == .succeeded)
    #expect(call(entries)?.subagent?.result == "First.")
    // Given more work: running again, its last answer kept.
    let again = decode([launch, launched, line, sendMessage])
    #expect(call(again)?.state == .running)
    #expect(call(again)?.subagent?.result == "First.")
    let second = decode([
      launch, launched, line, sendMessage, notification("completed", result: "Second."),
    ])
    #expect(call(second)?.state == .succeeded)
    #expect(call(second)?.subagent?.result == "Second.")
  }

  @Test("Stopping the turn leaves a sub-agent in the background running")
  func interruptKeepsBackground() {
    let bash =
      #"{"type":"assistant","uuid":"a3","message":{"content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"sleep 10"}}]}}"#
    let interrupted =
      #"{"type":"user","uuid":"u9","message":{"content":"[Request interrupted by user]"}}"#
    let entries = decode([launch, launched, bash, interrupted])
    #expect(call(entries)?.state == .running)
    #expect(entries.first { $0.id == "b1" }?.toolCall?.state == .interrupted)
  }

  @Test("Three sub-agents started together keep their own identifiers and results")
  func parallel() {
    let launches =
      #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"description":"One","prompt":"p1","subagent_type":"Explore"}},{"type":"tool_use","id":"t2","name":"Agent","input":{"description":"Two","prompt":"p2","subagent_type":"Explore"}},{"type":"tool_use","id":"t3","name":"Agent","input":{"description":"Three","prompt":"p3","subagent_type":"Plan"}}]}}"#
    let results = (1...3).map { index in
      #"{"type":"user","uuid":"r\#(index)","message":{"content":[{"type":"tool_result","tool_use_id":"t\#(index)","content":"launched"}]},"toolUseResult":{"status":"async_launched","agentId":"a\#(index)"}}"#
    }
    let done = (1...3).reversed().map { index in
      notification("completed", result: "Answer \(index)", agent: "a\(index)", call: "t\(index)")
    }
    let entries = decode([launches] + results + done)
    let calls = entries.compactMap(\.subagentCall)
    #expect(calls.map(\.callID) == ["t1", "t2", "t3"])
    #expect(calls.map { $0.subagent?.agentID } == ["a1", "a2", "a3"])
    #expect(calls.map { $0.subagent?.result } == ["Answer 1", "Answer 2", "Answer 3"])
    #expect(ConversationGrouping.blocks(entries).count == 1)
  }

  @Test("A skill run apart is a sub-agent named after the skill")
  func forkedSkill() {
    let entries = decode([
      #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"code-review","args":"197"}}]}}"#,
      #"{"type":"user","uuid":"u1","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Skill launched"}]},"toolUseResult":{"success":true,"commandName":"code-review","status":"forked","background":true,"agentId":"a1"}}"#,
    ])
    #expect(call(entries)?.kind == .subagent)
    #expect(call(entries)?.state == .running)
    #expect(call(entries)?.parameter(.description) == "/code-review 197")
    #expect(call(entries)?.subagent?.type == "code-review")
    #expect(call(entries)?.subagent?.agentID == "a1")
  }

  @Test("An agent type that does not exist: failed, with the CLI's words")
  func unknownType() {
    let entries = decode([
      launch,
      #"{"type":"user","uuid":"u1","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Agent type 'x' not found.","is_error":true}]},"toolUseResult":"Error: Agent type 'x' not found."}"#,
    ])
    #expect(call(entries)?.state == .failed(exitCode: nil))
    #expect(call(entries)?.subagent?.failure == "Agent type 'x' not found.")
  }

  @Test("A sub-agent's own transcript: its mission and its hand-back are left to its block")
  func ownTranscript() {
    let entries = decode(
      [
        #"{"type":"user","uuid":"m","isSidechain":true,"agentId":"a1","message":{"role":"user","content":"Read the diff and report."}}"#,
        #"{"type":"assistant","uuid":"x1","isSidechain":true,"agentId":"a1","message":{"content":[{"type":"text","text":"Looking."}]}}"#,
        #"{"type":"assistant","uuid":"x2","isSidechain":true,"agentId":"a1","message":{"content":[{"type":"tool_use","id":"r1","name":"Read","input":{"file_path":"/a.swift"}}]}}"#,
        #"{"type":"user","uuid":"x3","isSidechain":true,"agentId":"a1","message":{"content":[{"type":"tool_result","tool_use_id":"r1","content":"…"}]}}"#,
        #"{"type":"assistant","uuid":"x4","isSidechain":true,"agentId":"a1","message":{"content":[{"type":"tool_use","id":"h1","name":"SubagentHandback","input":{"message":"Report"}}]}}"#,
        #"{"type":"assistant","uuid":"x5","isSidechain":true,"agentId":"a1","message":{"content":[{"type":"tool_use","id":"n1","name":"Agent","input":{"description":"Deeper","prompt":"p"}}]}}"#,
      ], subagent: true)
    #expect(entries.map(\.id) == ["x1", "r1", "n1"])
    #expect(entries[1].toolCall?.state == .succeeded)
    #expect(entries[2].toolCall?.kind == .subagent)
  }

  @Test("Sub-agents' transcripts are listed from their records, never opened")
  func listing() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("subagents-\(UUID().uuidString)")
    let root = folder.appendingPathComponent("session.jsonl")
    let subagents = folder.appendingPathComponent("session/subagents")
    try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data(#"{"agentType":"Explore","description":"One","toolUseId":"t1","spawnDepth":1}"#.utf8)
      .write(to: subagents.appendingPathComponent("agent-a1.meta.json"))
    try Data(#"{"agentType":"general-purpose","description":"/code-review","name":"code-review","spawnDepth":1,"stoppedByUser":true}"#.utf8)
      .write(to: subagents.appendingPathComponent("agent-a2.meta.json"))
    try Data(
      (#"{"type":"user","message":{"role":"user","content":"Old prompt"}}"# + "\n{}\n").utf8
    ).write(to: subagents.appendingPathComponent("agent-a3.jsonl"))
    let found = SubagentTranscripts.claudeCode(beside: root).sorted { $0.agentID < $1.agentID }
    #expect(found.map(\.agentID) == ["a1", "a2", "a3"])
    #expect(found.map(\.toolUseID) == ["t1", nil, nil])
    #expect(found[0].file.lastPathComponent == "agent-a1.jsonl")
    #expect(found[1].stoppedByUser)
    #expect(SubagentTranscripts.claudeCodeFirstPrompt(of: found[2].file) == "Old prompt")
  }
}

@Suite("Reading sub-agents from a Codex rollout")
struct CodexSubagentTests {
  private func decode(_ lines: [String], isFork: Bool = false) -> [ConversationEntry] {
    let decoder = CodexConversationDecoder(isFork: isFork)
    for line in lines { decoder.consume(Data(line.utf8)) }
    return decoder.entries
  }

  private func activity(_ kind: String, id: String) -> String {
    #"{"timestamp":"2026-09-29T13:58:14.976Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"SubAgentActivity","id":"\#(id)","kind":"\#(kind)","agent_thread_id":"th-1","agent_path":"/root/review_relay"}}}"#
  }

  @Test("Started, given work, completed: one block following its thread")
  func lifecycle() {
    let started = decode([activity("started", id: "c1")])
    #expect(started.count == 1)
    #expect(started[0].toolCall?.kind == .subagent)
    #expect(started[0].toolCall?.state == .running)
    #expect(started[0].toolCall?.parameter(.description) == "review relay")
    #expect(started[0].toolCall?.subagent?.agentID == "th-1")
    let done = decode([activity("started", id: "c1"), activity("completed", id: "subagent-completed-x")])
    #expect(done.count == 1)
    #expect(done[0].toolCall?.state == .succeeded)
    #expect(done[0].toolCall?.subagent?.taskCount == 1)
    let again = decode([
      activity("started", id: "c1"), activity("completed", id: "d1"),
      activity("interacted", id: "c2"),
    ])
    #expect(again[0].toolCall?.state == .running)
    let twice = decode([
      activity("started", id: "c1"), activity("completed", id: "d1"),
      activity("interacted", id: "c2"), activity("completed", id: "d2"),
    ])
    #expect(twice[0].toolCall?.subagent?.taskCount == 2)
  }

  @Test("A sub-agent's rollout: the parent's history it copies first is left out")
  func fork() {
    let lines = [
      #"{"timestamp":"2026-09-29T13:58:14.937Z","type":"session_meta","payload":{"id":"th-1","timestamp":"2026-09-29T13:58:14.937Z"}}"#,
      #"{"timestamp":"2026-09-29T13:58:14.938Z","type":"event_msg","payload":{"type":"task_started","turn_id":"old","started_at":1790672096}}"#,
      #"{"timestamp":"2026-09-29T13:58:14.938Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"m-old","content":[{"type":"Text","text":"From the parent"}]}}}"#,
      #"{"timestamp":"2026-09-29T13:58:15.008Z","type":"event_msg","payload":{"type":"task_started","turn_id":"own","started_at":1790690295}}"#,
      #"{"timestamp":"2026-09-29T13:58:20.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"m-own","content":[{"type":"Text","text":"My review"}]}}}"#,
    ]
    #expect(decode(lines, isFork: true).map(\.id) == ["m-own"])
    #expect(decode(lines).map(\.id) == ["m-old", "m-own"])
  }
}
