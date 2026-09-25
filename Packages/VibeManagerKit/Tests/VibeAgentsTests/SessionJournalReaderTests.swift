import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeProcess

@testable import VibeAgents

@Suite("Reading a session's transcripts for its journal")
struct SessionJournalReaderTests {
  private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeJournal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func session(_ provider: String, _ identifier: String) -> WorkSession {
    WorkSession(
      name: "S",
      agent: SessionAgentConfiguration(providerID: provider, resumeIdentifier: identifier),
      status: .active)
  }

  private func append(_ text: String, to file: URL) throws {
    if let handle = try? FileHandle(forWritingTo: file) {
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(text.utf8))
      try handle.close()
    } else {
      try Data(text.utf8).write(to: file)
    }
  }

  private let claudeLines = [
    #"{"type":"user","cwd":"/r","gitBranch":"main","timestamp":"2026-09-25T10:00:00.000Z","message":{"role":"user","content":"Review https://gitlab.com/g/p/-/merge_requests/12"}}"#,
    #"{"type":"user","isMeta":true,"message":{"content":"<system-reminder>x</system-reminder>"}}"#,
    #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#,
    #"{"type":"assistant","cwd":"/r","gitBranch":"feat/x","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"gh pr create --fill","description":"Open it"}},{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/r/a.swift","new_string":"https://github.com/o/r/issues/99"}}]}}"#,
    #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"https://github.com/o/r/pull/80\n"}]}}"#,
    #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Opened the PR."}]}}"#,
    #"{"type":"system","subtype":"turn_duration","timestamp":"2026-09-25T10:01:00.000Z"}"#,
  ]

  @Test("Claude Code: prompts, tool calls, creation outputs, agent text and ends of turn")
  func claudeCode() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = "28538616-9a27-4cae-92a7-150d7511fc9d"
    let folder = root.appendingPathComponent("projects/-r", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("\(identifier).jsonl")
    try append(claudeLines.joined(separator: "\n") + "\n", to: file)
    let reader = SessionJournalReader(
      claudeProjects: root.appendingPathComponent("projects"),
      codexSessions: root.appendingPathComponent("sessions"))
    let reading = await reader.read(session("claude-code", identifier), from: [:])
    let events = reading.events.map(\.event)
    #expect(reading.foundTranscript)
    #expect(events.count == 7)
    #expect(
      events.first
        == .prompt(
          "Review https://gitlab.com/g/p/-/merge_requests/12",
          at: Date(timeIntervalSince1970: 1_790_330_400)))
    guard case .toolCall(let bash) = events[1], case .toolCall(let edit) = events[2] else {
      Issue.record("no tool calls")
      return
    }
    #expect(bash.command == "gh pr create --fill")
    #expect(bash.branch == "feat/x")
    #expect(bash.summary == "Bash: gh pr create --fill")
    // What an edit writes is code, not a resource used.
    #expect(edit.strings.isEmpty)
    #expect(edit.summary == "Edit: a.swift")
    #expect(
      events[3]
        == .creationOutput(
          command: "gh pr create --fill", directory: "/r",
          output: "https://github.com/o/r/pull/80\n", at: nil))
    #expect(events[4] == .agentText("Opened the PR.", at: nil))
    #expect(events[5] == .turnEnded(at: nil))
    #expect(events[6] == .turnEnded(at: Date(timeIntervalSince1970: 1_790_330_460)))
  }

  @Test("The agent's folder is watched before it has named its conversation")
  func directoriesBeforeIdentifier() async {
    let reader = SessionJournalReader(
      claudeProjects: URL(fileURLWithPath: "/p"), codexSessions: URL(fileURLWithPath: "/s"))
    let unnamed = WorkSession(
      name: "S", agent: SessionAgentConfiguration(providerID: "codex"), status: .active)
    #expect(await reader.transcriptDirectories(for: unnamed) == ["/s"])
  }

  @Test("Only whole lines, resumed from the cursor; a replaced file is read from its start")
  func cursors() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = "b3d22715-737b-4f7e-b8fe-97bc7bd5faa5"
    let folder = root.appendingPathComponent("projects/-r", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("\(identifier).jsonl")
    let prompt = #"{"type":"user","message":{"content":"one"}}"#
    try append(prompt + "\n" + #"{"type":"user","mess"#, to: file)
    let reader = SessionJournalReader(
      claudeProjects: root.appendingPathComponent("projects"),
      codexSessions: root.appendingPathComponent("sessions"))
    let session = session("claude-code", identifier)
    let first = await reader.read(session, from: [:])
    #expect(first.events.count == 1)
    try append(#"age":{"content":"two"}}"# + "\n", to: file)
    // A new reader, as after a relaunch: the cursor alone says where to resume.
    let relaunched = SessionJournalReader(
      claudeProjects: root.appendingPathComponent("projects"),
      codexSessions: root.appendingPathComponent("sessions"))
    let second = await relaunched.read(session, from: first.cursors)
    #expect(second.events.map(\.event) == [.prompt("two", at: nil)])
    let third = await relaunched.read(session, from: second.cursors)
    #expect(third.events.isEmpty)
    try FileManager.default.removeItem(at: file)
    try append(#"{"type":"user","message":{"content":"new"}}"# + "\n", to: file)
    let fourth = await relaunched.read(session, from: third.cursors)
    #expect(fourth.events.map(\.event) == [.prompt("new", at: nil)])
  }

  @Test("Codex: user messages but not its instructions, exec commands, outputs and task ends")
  func codex() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = "01a0d87f-781a-7fd2-85ab-8dab801e4b09"
    let calendar = Calendar(identifier: .gregorian)
    let parts = calendar.dateComponents([.year, .month, .day], from: Date())
    let folder = root.appendingPathComponent(
      String(format: "sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!),
      isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("rollout-x-\(identifier).jsonl")
    let lines = [
      #"{"type":"turn_context","payload":{"cwd":"/w"}}"#,
      ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"},{"type":"input_text","text":"<environment_context>x</environment_context>"},{"type":"input_text","text":"Fix #3"}]}}"##,
      #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"c1","arguments":"{\"cmd\":\"glab mr create --fill\",\"workdir\":\"/w/api\"}"}}"#,
      #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"https://gitlab.com/g/p/-/merge_requests/7"}}"#,
      #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c2","input":"const r = await tools.exec_command({\"cmd\":\"git push -u origin x\",\"workdir\":\"/w/web\"});"}}"#,
      #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"c3","input":"*** Begin Patch\n*** Update File: /w/a.swift\n*** End Patch"}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}"#,
      #"{"type":"event_msg","payload":{"type":"task_complete"}}"#,
    ]
    try append(lines.joined(separator: "\n") + "\n", to: file)
    let reader = SessionJournalReader(
      claudeProjects: root.appendingPathComponent("projects"),
      codexSessions: root.appendingPathComponent("sessions"))
    let events = await reader.read(session("codex", identifier), from: [:]).events.map(\.event)
    #expect(events.first == .prompt("Fix #3", at: nil))
    let calls = events.compactMap { event -> TranscriptToolCall? in
      if case .toolCall(let call) = event { return call }
      return nil
    }
    #expect(calls.map(\.command) == ["glab mr create --fill", "git push -u origin x", nil])
    #expect(calls.map(\.directory) == ["/w/api", "/w/web", "/w"])
    #expect(calls.last?.summary == "apply_patch: a.swift")
    #expect(
      events.contains(
        .creationOutput(
          command: "glab mr create --fill", directory: "/w/api",
          output: "https://gitlab.com/g/p/-/merge_requests/7", at: nil)))
    #expect(events.suffix(2) == [.agentText("Done.", at: nil), .turnEnded(at: nil)])
  }
}

@Suite("The commands that write a summary")
struct SummaryCommandTests {
  private let request = SummaryRequest(digest: "## Turn 1", turnCount: 2, language: "fr-FR")

  @Test("Claude Code: no tools, no MCP, no hooks, no persistence, a schema")
  func claudeArguments() throws {
    let arguments = try ClaudeCodeSummaryCommand().arguments(
      for: request, in: URL(fileURLWithPath: "/tmp"), models: [])
    #expect(arguments.prefix(4) == ["-p", "--model", "haiku", "--tools"])
    #expect(arguments[4] == "")
    for flag in [
      "--strict-mcp-config", "--no-session-persistence", "--setting-sources", "--settings",
      "--system-prompt", "--json-schema",
    ] {
      #expect(arguments.contains(flag))
    }
    #expect(!arguments.contains("--bare"))
    let settings = try #require(arguments.firstIndex(of: "--settings"))
    #expect(arguments[settings + 1] == #"{"disableAllHooks":true}"#)
    #expect(
      ClaudeCodeSummaryCommand().additionalEnvironment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == "1")
  }

  @Test("Claude Code: the answer is its structured output, checked")
  func claudeAnswer() throws {
    let command = ClaudeCodeSummaryCommand()
    let good = BoundedProcessResult(
      termination: .exited(0),
      standardOutput: Data(
        #"{"type":"result","is_error":false,"structured_output":{"entries":[{"text":"Revu la MR","turn":1},{"text":"Poussé","turn":9}]}}"#
          .utf8))
    let entries = try command.entries(
      from: good, in: URL(fileURLWithPath: "/tmp"), request: request)
    #expect(
      entries == [SummaryEntry(text: "Revu la MR", turn: 1), SummaryEntry(text: "Poussé", turn: 2)])

    let empty = BoundedProcessResult(
      termination: .exited(0),
      standardOutput: Data(#"{"is_error":false,"structured_output":{"entries":[]}}"#.utf8))
    #expect(throws: SummaryError.self) {
      try command.entries(from: empty, in: URL(fileURLWithPath: "/tmp"), request: request)
    }
    let tooLong = BoundedProcessResult(
      termination: .exited(0),
      standardOutput: Data(
        #"{"structured_output":{"entries":[{"text":"\#(String(repeating: "a", count: 300))","turn":1}]}}"#
          .utf8))
    #expect(throws: SummaryError.self) {
      try command.entries(from: tooLong, in: URL(fileURLWithPath: "/tmp"), request: request)
    }
  }

  @Test("An error output tells an old CLI and a signed-out one from a failed pass")
  func failures() {
    let old = BoundedProcessResult(
      termination: .exited(2), standardError: Data("error: unknown option '--json-schema'".utf8))
    #expect(CommandLineSummarizer.failure(of: old) == .unavailable(.outdated))
    let signedOut = BoundedProcessResult(
      termination: .exited(1), standardOutput: Data("Invalid API key · Please run /login".utf8))
    #expect(CommandLineSummarizer.failure(of: signedOut) == .unavailable(.signedOut))
    let other = BoundedProcessResult(termination: .exited(1))
    #expect(CommandLineSummarizer.failure(of: other) == .failed("exit 1"))
  }

  @Test("Codex: ephemeral, read only, its schema and answer in files, the lightest model")
  func codex() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "VibeSummary-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let command = CodexSummaryCommand()
    let arguments = try command.arguments(
      for: request, in: workspace,
      models: [
        AgentModel(id: "gpt-5", displayName: "GPT-5", isDefault: true),
        AgentModel(id: "gpt-5-mini", displayName: "mini", isDefault: false),
      ])
    #expect(
      arguments == [
        "exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only",
        "--disable", "hooks", "--disable", "apps", "--disable", "plugins",
        "-c", "mcp_servers={}", "-c", "tools.web_search=false", "-m", "gpt-5-mini",
        "--output-schema", workspace.appendingPathComponent("schema.json").path,
        "-o", workspace.appendingPathComponent("answer.json").path, "-",
      ])
    #expect(
      FileManager.default.fileExists(atPath: workspace.appendingPathComponent("schema.json").path))
    #expect(String(decoding: command.input(for: request), as: UTF8.self).hasSuffix("## Turn 1"))
    try Data(#"{"entries":[{"text":"Corrigé le test","turn":2}]}"#.utf8).write(
      to: workspace.appendingPathComponent("answer.json"))
    let entries = try command.entries(
      from: BoundedProcessResult(termination: .exited(0)), in: workspace, request: request)
    #expect(entries == [SummaryEntry(text: "Corrigé le test", turn: 2)])
  }
}
