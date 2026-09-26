import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

/// Runs a hook command the way a CLI does: through a shell, with its input on stdin.
func runHook(
  _ command: String, input: String, log: URL?
) throws -> (status: Int32, output: String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = ["-c", command]
  var environment = ["PATH": "/usr/bin:/bin"]
  if let log { environment[AgentActivityHookCommand.environmentKey] = log.path }
  process.environment = environment
  let stdin = Pipe()
  let stdout = Pipe()
  process.standardInput = stdin
  process.standardOutput = stdout
  try process.run()
  try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
  try stdin.fileHandleForWriting.close()
  process.waitUntilExit()
  let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  return (process.terminationStatus, output)
}

func temporaryLog() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("vibe-activity-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.appendingPathComponent("session.log")
}

func lines(of url: URL) -> [[String]] {
  let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  return text.split(separator: "\n").map {
    $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
  }
}

@Suite("The activity hook command")
struct AgentActivityHookCommandTests {
  @Test("It appends one line: the event, the time, nothing of a dropped input")
  func dropsInput() throws {
    let log = try temporaryLog()
    let command = AgentActivityHookCommand.command(event: "Stop", payload: .drop)
    let result = try runHook(command, input: #"{"secret":"prompt"}"#, log: log)
    #expect(result.status == 0)
    #expect(result.output.isEmpty)
    let written = lines(of: log)
    #expect(written.count == 1)
    #expect(written.first?.first == "Stop")
    #expect(written.first.map { TimeInterval($0[1]) != nil } == true)
    #expect(written.first?.last == "")
  }

  @Test("A kept input is written on the same line, without its line breaks")
  func keepsInput() throws {
    let log = try temporaryLog()
    let command = AgentActivityHookCommand.command(event: "PermissionRequest", payload: .keep)
    let result = try runHook(command, input: "{\"tool_name\":\"Bash\"}\n", log: log)
    #expect(result.status == 0)
    #expect(lines(of: log).first?.last == #"{"tool_name":"Bash"}"#)
  }

  @Test("A kept input is cut at the limit, and the CLI can still write all of it")
  func cutsLongInput() throws {
    let log = try temporaryLog()
    let command = AgentActivityHookCommand.command(event: "PermissionRequest", payload: .keep)
    let input = String(repeating: "x", count: 200_000)
    let result = try runHook(command, input: input, log: log)
    #expect(result.status == 0)
    #expect(lines(of: log).first?.last?.count == AgentActivityHookCommand.payloadByteLimit)
  }

  @Test("A match writes back only the text it looked for, when it is there")
  func matches() throws {
    let log = try temporaryLog()
    let marker = #""prompt":"<task-notification>"#
    let command = AgentActivityHookCommand.command(
      event: "UserPromptSubmit", payload: .match(marker))
    _ = try runHook(command, input: #"{"prompt":"<task-notification>\n<id>1"}"#, log: log)
    _ = try runHook(command, input: #"{"prompt":"what's the weather?"}"#, log: log)
    let written = lines(of: log)
    #expect(written.map(\.last) == [marker, ""])
  }

  @Test("Fields write back only those fields, as JSON, escapes kept, and nothing when missing")
  func fields() throws {
    let log = try temporaryLog()
    let command = AgentActivityHookCommand.command(
      event: "PostToolUse", payload: .fields(["agent_id", "tool_name", "command"]))
    _ = try runHook(
      command,
      input:
        #"{"session_id":"s","tool_name":"Bash","tool_input":{"command":"echo \"tool_name\":\"x\""},"tool_response":{"stdout":"secret","command":"no"}}"#,
      log: log)
    _ = try runHook(command, input: #"{"session_id":"s"}"#, log: log)
    let written = lines(of: log).map(\.last)
    #expect(written == [#"{"tool_name":"Bash","command":"echo \"tool_name\":\"x\""}"#, ""])
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data((written[0] ?? "").utf8)) as? [String: String])
    #expect(object["command"] == #"echo "tool_name":"x""#)
  }

  @Test("Without a log to write to, or with one it cannot write, it still succeeds silently")
  func neverFails() throws {
    let command = AgentActivityHookCommand.command(event: "Stop", payload: .keep)
    #expect(try runHook(command, input: "{}", log: nil) == (0, ""))
    let unwritable = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/session.log")
    #expect(try runHook(command, input: "{}", log: unwritable) == (0, ""))
  }

  @Test("Its words are fixed: Codex remembers its approval by them")
  func golden() {
    #expect(
      AgentActivityHookCommand.command(event: "Stop", payload: .drop)
        == "/bin/sh -c '" + AgentActivityHookCommand.script
        + "' vibe-activity Stop drop 2>/dev/null"
    )
    #expect(AgentActivityHookCommand.script.contains("'") == false)
  }
}

@Suite("Claude Code activity reporting")
struct ClaudeCodeActivityReportingTests {
  private func plan(_ arguments: [String]) -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: ClaudeCodeAgentProvider.id, executablePath: "/usr/local/bin/claude",
      arguments: arguments, environment: ["HOME": "/Users/a"],
      workingDirectoryPath: "/Users/a/dev", promptDelivery: .argument)
  }

  @Test("The settings go before the prompt, and the log in the environment")
  func instrumentsPlan() throws {
    let provider = ClaudeCodeAgentProvider.make(environment: ["HOME": "/Users/a"])
    let log = URL(fileURLWithPath: "/data/AgentActivity/s.log")
    let reported = provider.reportingActivity(
      plan(["--session-id", "abc", "--", "--fix"]), to: log)
    #expect(Array(reported.arguments.prefix(2)) == ["--session-id", "abc"])
    #expect(reported.arguments[2] == "--settings")
    #expect(Array(reported.arguments.suffix(2)) == ["--", "--fix"])
    #expect(reported.environment[AgentActivityHookCommand.environmentKey] == log.path)
    #expect(reported.environment["HOME"] == "/Users/a")

    let resumed = provider.reportingActivity(plan(["--resume", "abc"]), to: log)
    #expect(Array(resumed.arguments.suffix(2)).first == "--settings")
  }

  @Test("Every event is hooked once, and tools only when they ask the user")
  func settingsShape() throws {
    let json = ClaudeCodeActivityHooks.settings()
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let hooks = try #require(object["hooks"] as? [String: [[String: Any]]])
    #expect(Set(hooks.keys) == Set(ClaudeCodeActivityHooks.hooks.map(\.event)))
    #expect(hooks["PreToolUse"]?.first?["matcher"] as? String == "AskUserQuestion|ExitPlanMode")
    #expect(hooks["PostToolUse"]?.first?["matcher"] == nil)
    let stop = try #require((hooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.first)
    #expect(stop["type"] as? String == "command")
    #expect(stop["timeout"] as? Int == AgentActivityHookCommand.timeoutSeconds)
    #expect(json == ClaudeCodeActivityHooks.settings())
  }
}

/// Payloads as Claude Code 2.1.282 sent them to the hooks during the spike of #45, with the paths
/// and identifiers replaced.
private enum ClaudePayloads {
  static let sessionStart =
    #"{"session_id":"s","transcript_path":"/Users/a/.claude/projects/-Users-a-dev/s.jsonl","cwd":"/Users/a/dev","hook_event_name":"SessionStart","source":"startup","model":"claude-haiku-4-5-20251001"}"#
  static let askUserQuestion =
    #"{"session_id":"s","hook_event_name":"PermissionRequest","permission_mode":"default","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Tea or coffee?"}]}}"#
  static let bashPermission =
    #"{"session_id":"s","hook_event_name":"PermissionRequest","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"./long.sh"}}"#
  static let exitPlanMode =
    #"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{}}"#
  static let idle =
    #"{"session_id":"s","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#
  static let permissionNotification =
    #"{"session_id":"s","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}"#
}

@Suite("Claude Code signals")
struct ClaudeCodeSignalDecoderTests {
  private let decoder = ClaudeCodeSignalDecoder(makeInterruptionWatch: { _ in
    AsyncStream { $0.yield(.interrupted) }
  })

  private func event(_ name: String, _ payload: String? = nil) -> AgentActivityEvent {
    AgentActivityEvent(name: name, date: Date(), payload: payload.map { Data($0.utf8) })
  }

  @Test("Each hook says what it says")
  func signals() {
    #expect(
      decoder.signal(for: event("SessionStart", ClaudePayloads.sessionStart)) == .channelConfirmed)
    #expect(decoder.signal(for: event("UserPromptSubmit")) == .promptSubmitted(byUser: true))
    #expect(
      decoder.signal(for: event("UserPromptSubmit", #""prompt":"<task-notification>"#))
        == .promptSubmitted(byUser: false))
    #expect(
      decoder.signal(for: event("PermissionRequest", ClaudePayloads.bashPermission))?.withoutNotice
        == .questionAsked(.approval, tool: "Bash"))
    #expect(
      decoder.signal(for: event("PermissionRequest", ClaudePayloads.askUserQuestion))?.withoutNotice
        == .questionAsked(.question, tool: "AskUserQuestion"))
    #expect(
      decoder.signal(for: event("PreToolUse", ClaudePayloads.exitPlanMode))?.withoutNotice
        == .questionAsked(.approval, tool: "ExitPlanMode"))
    // A permission for a large `Write` is cut short past the byte limit: still a permission.
    #expect(
      decoder.signal(for: event("PermissionRequest", #"{"tool_name":"Ba"#))?.withoutNotice
        == .questionAsked(.approval))
    #expect(decoder.signal(for: event("Elicitation"))?.withoutNotice == .questionAsked(.question))
    for name in ["PostToolUse", "PostToolUseFailure", "PermissionDenied", "ElicitationResult"] {
      #expect(decoder.signal(for: event(name)) == .questionResolved)
    }
    for name in ["PostToolUse", "PostToolUseFailure", "PermissionDenied"] {
      #expect(decoder.signal(for: event(name, #"{"tool_name":"Bash"}"#)) == .toolFinished("Bash"))
    }
    #expect(decoder.signal(for: event("Stop")) == .turnEnded)
    #expect(decoder.signal(for: event("StopFailure")) == .turnEnded)
    #expect(decoder.signal(for: event("SessionEnd")) == .agentEnded)
    #expect(decoder.signal(for: event("Notification", ClaudePayloads.idle)) == .waitingForInput)
  }

  @Test("What cannot be read, or repeats another hook, says nothing")
  func silence() {
    #expect(
      decoder.signal(for: event("Notification", ClaudePayloads.permissionNotification)) == nil)
    #expect(decoder.signal(for: event("PreToolUse", #"{"tool_name":"Bash"}"#))?.withoutNotice == nil)
    #expect(decoder.signal(for: event("SubagentStop")) == nil)
  }

  @Test("The transcript a session starts with is where its interruptions are read")
  func transcriptWatch() async {
    #expect(decoder.additionalSignals(after: event("Stop")) == nil)
    #expect(
      decoder.additionalSignals(after: event("SessionStart", #"{"transcript_path":"relative"}"#))
        == nil)
    let stream = decoder.additionalSignals(
      after: event("SessionStart", ClaudePayloads.sessionStart))
    var iterator = stream?.makeAsyncIterator()
    #expect(await iterator?.next() == .interrupted)
  }

  @Test("Enter and the option digits answer a permission")
  func keys() {
    #expect(decoder.approvalAnswerKeys.contains([0x0D]))
    #expect(decoder.approvalAnswerKeys.contains([0x31]))
    #expect(!decoder.approvalAnswerKeys.contains([0x1B]))
  }
}

@Suite("Claude Code interruptions in the transcript")
struct ClaudeCodeInterruptionWatchTests {
  private static let interrupted =
    #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
  private static let interruptedTool =
    #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
  private static let quoted =
    #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t","type":"tool_result","content":"  19 [Request interrupted by user for tool use]"}]}}"#

  @Test("Only the line the CLI writes counts, in both of its forms")
  func recognisesTheLine() {
    #expect(ClaudeCodeInterruptionWatch.isInterruption(Data(Self.interrupted.utf8)))
    #expect(ClaudeCodeInterruptionWatch.isInterruption(Data(Self.interruptedTool.utf8)))
    #expect(!ClaudeCodeInterruptionWatch.isInterruption(Data(Self.quoted.utf8)))
    #expect(!ClaudeCodeInterruptionWatch.isInterruption(Data("[Request interrupted by user]".utf8)))
  }

  @Test("An interruption written after the watch starts is reported, the old ones are not")
  func followsTheFile() async throws {
    let url = try temporaryLog().deletingLastPathComponent().appendingPathComponent("t.jsonl")
    try Data((Self.interrupted + "\n").utf8).write(to: url)
    let watch = ClaudeCodeInterruptionWatch(transcript: url, pollInterval: .milliseconds(20))
    let stream = watch.signals()
    try await Task.sleep(for: .milliseconds(60))
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((Self.quoted + "\n" + Self.interruptedTool + "\n").utf8))
    try handle.close()

    let received = await withTaskGroup(of: AgentSignal?.self) { group in
      group.addTask {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
    #expect(received == .interrupted)
  }
}

@Suite("Codex activity reporting")
struct CodexActivityReportingTests {
  @Test("One -c option per event, before the positionals")
  func options() {
    let plan = AgentLaunchPlan(
      providerID: CodexAgentProvider.id, executablePath: "/usr/local/bin/codex",
      arguments: ["resume", "-C", "/Users/a/dev", "--", "rollout-1"], environment: [:],
      workingDirectoryPath: "/Users/a/dev", promptDelivery: .none)
    let reported = CodexAgentProvider.make(environment: [:]).reportingActivity(
      plan, to: URL(fileURLWithPath: "/data/s.log"))
    let count = CodexActivityHooks.hooks.count
    #expect(Array(reported.arguments.prefix(3)) == ["resume", "-C", "/Users/a/dev"])
    #expect(Array(reported.arguments.suffix(2)) == ["--", "rollout-1"])
    #expect(reported.arguments.filter { $0 == "-c" }.count == count)
    #expect(CodexActivityHooks.hookOptions(in: reported.arguments).count == count * 2)
  }

  @Test("Each option is TOML Codex reads back as the very command")
  func tomlValue() throws {
    let options = CodexActivityHooks.options()
    let stop = try #require(options.first { $0.hasPrefix("hooks.Stop=") })
    let command = AgentActivityHookCommand.command(event: "Stop", payload: .drop)
    // A JSON string literal is a TOML basic string: reading it back as JSON is reading it as TOML.
    let quoted = try #require(stop.range(of: "command=").map { stop[$0.upperBound...] })
    let literal = String(quoted.dropLast("}]}]".count))
    let decoded =
      try JSONSerialization.jsonObject(
        with: Data(("[" + literal + "]").utf8)) as? [String]
    #expect(decoded == [command])
    #expect(stop.contains("timeout=\(AgentActivityHookCommand.timeoutSeconds)"))
  }

  @Test("Codex's own interruption is read, and y, a, p, n and Enter answer it")
  func decoder() {
    let decoder = CodexSignalDecoder()
    let expected: [String: AgentSignal] = [
      "SessionStart": .channelConfirmed, "UserPromptSubmit": .promptSubmitted(byUser: true),
      "PermissionRequest": .questionAsked(.approval), "PostToolUse": .questionResolved,
      "Stop": .turnEnded, "Interrupt": .interrupted, "SessionEnd": .agentEnded,
    ]
    for (name, signal) in expected {
      #expect(
        decoder.signal(for: AgentActivityEvent(name: name, date: Date()))?.withoutNotice == signal)
    }
    #expect(decoder.approvalAnswerKeys == [[0x79], [0x61], [0x70], [0x6E], [0x0D]])
  }
}

extension AgentSignal {
  /// The signal without the request it carries (#40), for comparing only what #45 reads.
  var withoutNotice: AgentSignal {
    if case .questionAsked(let kind, let tool, _) = self { return .questionAsked(kind, tool: tool) }
    return self
  }
}
