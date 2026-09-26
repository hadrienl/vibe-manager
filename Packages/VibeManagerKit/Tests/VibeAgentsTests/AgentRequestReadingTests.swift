import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

/// Payloads as the CLIs sent them to their hooks during the spike of #40 — Claude Code 2.1.282,
/// Codex 0.157.1 — with paths and identifiers replaced.
enum RequestPayloads {
  static let bash =
    #"{"session_id":"s","transcript_path":"/Users/a/.claude/projects/p/s.jsonl","cwd":"/Users/a/dev","prompt_id":"p","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"touch hello.txt","description":"Create empty file named hello.txt"},"permission_suggestions":[{"type":"addDirectories","directories":["/Users/a/dev"],"destination":"session"},{"type":"setMode","mode":"acceptEdits","destination":"session"}]}"#
  static let subAgentBash =
    #"{"session_id":"s","prompt_id":"p","permission_mode":"default","agent_id":"a89e4f8137e913354","agent_type":"general-purpose","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"touch a.txt","description":"Create empty file a.txt"},"permission_suggestions":[{"type":"addDirectories","directories":["/Users/a/dev"],"destination":"session"}]}"#
  /// What the hook of a finishing tool keeps of it (`Payload.fields`).
  static let subAgentDone = #"{"agent_id":"a89e4f8137e913354","tool_name":"Bash","command":"touch a.txt"}"#
  static let question =
    #"{"session_id":"s","cwd":"/Users/a/dev","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Tea or coffee?","header":"Beverage","options":[{"label":"Tea","description":"Hot or cold tea"},{"label":"Coffee","description":"Your daily brew"}],"multiSelect":false}]},"tool_use_id":"toolu_1"}"#
  static let twoQuestions =
    #"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Tea or coffee?","header":"Drink","options":[{"label":"Tea"},{"label":"Coffee"}],"multiSelect":false},{"question":"Sugar?","header":"Sugar","options":[{"label":"Yes"},{"label":"No"}],"multiSelect":false}]}}"#
  static let toppings =
    #"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which toppings?","header":"Toppings","options":[{"label":"Cheese"},{"label":"Ham"},{"label":"Olives"}],"multiSelect":true}]}}"#
  static let plan =
    ###"{"hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{"plan":"## Plan\n- Create plan.txt with Write."}}"###
  static let mcp =
    #"{"hook_event_name":"PermissionRequest","tool_name":"mcp__github__create_issue","tool_input":{"title":"Bug","body":"It breaks"}}"#
  static let codexBash =
    #"{"session_id":"s","turn_id":"t","transcript_path":"/Users/a/.codex/sessions/2026/09/26/rollout-s.jsonl","cwd":"/Users/a/dev","hook_event_name":"PermissionRequest","model":"gpt","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"touch hello.txt","description":"Allow creating the requested empty hello.txt file in the current directory?"}}"#
  static let codexPatch =
    #"{"session_id":"s","turn_id":"t","hook_event_name":"PermissionRequest","model":"gpt","permission_mode":"default","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: notes.txt\n+hello\n*** End Patch"}}"#
  static let codexQuestionCall =
    #"{"timestamp":"2026-09-26T08:12:22.625Z","type":"response_item","payload":{"type":"function_call","id":"fc_1","name":"request_user_input","arguments":"{\"questions\":[{\"header\":\"Drink\",\"id\":\"drink_choice\",\"options\":[{\"description\":\"Choose tea.\",\"label\":\"Tea (Recommended)\"},{\"description\":\"Choose coffee.\",\"label\":\"Coffee\"}],\"question\":\"Tea or coffee?\"}]}","call_id":"call_1"}}"#
  static let codexQuestionOutput =
    #"{"timestamp":"2026-09-26T08:12:33.438Z","type":"response_item","payload":{"type":"function_call_output","id":"fco_1","call_id":"call_1","output":"aborted by user after 10.8s"}}"#
  static let codexOtherOutput =
    #"{"timestamp":"2026-09-26T08:12:33.438Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_2","output":"ok"}}"#
}

private func event(_ name: String, _ payload: String?) -> AgentActivityEvent {
  AgentActivityEvent(name: name, date: Date(), payload: payload.map { Data($0.utf8) })
}

private func notice(of signal: AgentSignal?) -> AgentRequestNotice? {
  if case .questionAsked(_, _, let notice) = signal { return notice }
  return nil
}

@Suite("Reading what an agent asks")
struct AgentRequestReadingTests {
  private let claude = ClaudeCodeSignalDecoder(makeInterruptionWatch: { _ in AsyncStream { _ in } })

  @Test("A permission names its tool, its exact command, and what always allowing would allow")
  func permission() throws {
    let notice = try #require(
      notice(of: claude.signal(for: event("PermissionRequest", RequestPayloads.bash))))
    #expect(notice.isShown)
    guard case .permission(let permission) = notice.content else {
      Issue.record("not a permission")
      return
    }
    #expect(permission.tool == .shell)
    #expect(permission.subject == "touch hello.txt")
    #expect(permission.purpose == "Create empty file named hello.txt")
    #expect(permission.workingDirectory == "/Users/a/dev")
    #expect(permission.isComplete)
    #expect(
      permission.alwaysAllow
        == AgentAlwaysAllow(rules: [.directories(["/Users/a/dev"]), .mode("acceptEdits")], scope: .session))
    #expect(notice.reference == AgentToolReference(tool: "Bash", subject: "touch hello.txt"))
  }

  @Test("A sub-agent's permission is told apart, and the tool it runs settles it")
  func subAgent() throws {
    let asked = try #require(
      notice(of: claude.signal(for: event("PermissionRequest", RequestPayloads.subAgentBash))))
    #expect(asked.reference.agentID == "a89e4f8137e913354")
    let done = claude.signal(for: event("PostToolUse", RequestPayloads.subAgentDone))
    #expect(
      done == .toolFinished("Bash", agentID: "a89e4f8137e913354", subject: "touch a.txt"))
    #expect(asked.reference.match(AgentToolReference(tool: "Bash", agentID: "a89e4f8137e913354", subject: "touch a.txt")) == .same)
  }

  @Test("A question is announced before its dialog is drawn, with its options")
  func question() throws {
    let announced = try #require(
      notice(of: claude.signal(for: event("PreToolUse", RequestPayloads.question))))
    #expect(!announced.isShown)
    #expect(
      announced.content
        == .questions([
          AgentQuestion(
            header: "Beverage", text: "Tea or coffee?",
            options: [
              .init(label: "Tea", description: "Hot or cold tea"),
              .init(label: "Coffee", description: "Your daily brew"),
            ])
        ]))
    let shown = try #require(
      notice(
        of: claude.signal(
          for: event(
            "PermissionRequest",
            RequestPayloads.question.replacingOccurrences(
              of: "PreToolUse", with: "PermissionRequest")))))
    #expect(shown.isShown)
    #expect(shown.reference.match(announced.reference) == .same)
  }

  @Test("A plan, an MCP call, a cut-short report")
  func others() throws {
    let plan = try #require(
      notice(of: claude.signal(for: event("PermissionRequest", RequestPayloads.plan))))
    #expect(plan.content == .plan(excerpt: "## Plan\n- Create plan.txt with Write.", isComplete: true))

    let mcp = try #require(
      notice(of: claude.signal(for: event("PermissionRequest", RequestPayloads.mcp))))
    guard case .permission(let permission) = mcp.content else {
      Issue.record("not a permission")
      return
    }
    #expect(permission.tool == .mcp(server: "github", tool: "create_issue"))
    #expect(permission.details?.contains("It breaks") == true)

    let cut = String(RequestPayloads.bash.prefix(300))
    let truncated = try #require(notice(of: claude.signal(for: event("PermissionRequest", cut))))
    #expect(truncated.content == .unreadable(tool: "Bash"))
    #expect(truncated.isShown)
  }

  @Test("A long plan is cut for the card, and says so")
  func longPlan() {
    let lines = (1...60).map { "- step \($0)" }.joined(separator: "\n")
    let content = AgentRequestReading.plan(in: ["plan": lines])
    guard case .plan(let excerpt, let isComplete) = content else {
      Issue.record("not a plan")
      return
    }
    #expect(!isComplete)
    #expect(excerpt.split(separator: "\n").count == AgentRequestReading.planExcerptLineLimit)
  }

  @Test("Codex's permissions: a command, a patch, and what always allowing means for each")
  func codex() throws {
    let decoder = CodexSignalDecoder()
    let bash = try #require(
      notice(of: decoder.signal(for: event("PermissionRequest", RequestPayloads.codexBash))))
    guard case .permission(let command) = bash.content else {
      Issue.record("not a permission")
      return
    }
    #expect(command.subject == "touch hello.txt")
    #expect(command.alwaysAllow == AgentAlwaysAllow(rules: [.commandPrefix], scope: .session))

    let patch = try #require(
      notice(of: decoder.signal(for: event("PermissionRequest", RequestPayloads.codexPatch))))
    guard case .permission(let edit) = patch.content else {
      Issue.record("not a permission")
      return
    }
    #expect(edit.tool == .patch)
    #expect(edit.subject == "notes.txt")
    #expect(edit.details?.contains("+hello") == true)
    #expect(edit.alwaysAllow == AgentAlwaysAllow(rules: [.files], scope: .session))
  }

  @Test("A JSON string value is read whole, escapes resolved, even from a text cut short")
  func firstString() {
    #expect(
      AgentRequestReading.firstString("command", in: #"{"command":"echo \"hi\" \\ ok","x":1"#)
        == #"echo "hi" \ ok"#)
    #expect(AgentRequestReading.firstString("command", in: #"{"command":"unfinished"#) == nil)
    #expect(
      AgentRequestReading.firstString("command", in: #"{"x":"\"command\":\"no\"","command":"yes"}"#)
        == "yes")
  }
}

@Suite("Codex questions in the rollout")
struct CodexQuestionWatchTests {
  @Test("A question is read from its call, and settled by its own output only")
  func lines() throws {
    var pending: Set<String> = []
    let asked = CodexQuestionWatch.signals(
      in: Data(RequestPayloads.codexQuestionCall.utf8), pending: &pending)
    let notice = try #require(asked.first.flatMap(notice(of:)))
    #expect(!notice.isShown)
    #expect(notice.key == "codex:call_1")
    #expect(
      notice.content
        == .questions([
          AgentQuestion(
            header: "Drink", text: "Tea or coffee?",
            options: [
              .init(label: "Tea (Recommended)", description: "Choose tea."),
              .init(label: "Coffee", description: "Choose coffee."),
            ])
        ]))
    #expect(
      CodexQuestionWatch.signals(in: Data(RequestPayloads.codexOtherOutput.utf8), pending: &pending)
        .isEmpty)
    #expect(
      CodexQuestionWatch.signals(
        in: Data(RequestPayloads.codexQuestionOutput.utf8), pending: &pending)
        == [.toolFinished("request_user_input", subject: "call_1")])
    #expect(pending.isEmpty)
  }

  @Test("The rollout of the session's folder is found, and its questions followed")
  func followsRollout() async throws {
    let sessions = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-sessions-\(UUID().uuidString)", isDirectory: true)
    let since = Date()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let parts = calendar.dateComponents([.year, .month, .day], from: since)
    let folder = sessions.appendingPathComponent(
      String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let work = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    let other = folder.appendingPathComponent("rollout-other.jsonl")
    try Data(#"{"type":"session_meta","payload":{"cwd":"/elsewhere"}}"#.utf8).write(to: other)
    let rollout = folder.appendingPathComponent("rollout-mine.jsonl")
    let meta = #"{"type":"session_meta","payload":{"cwd":"\#(work)"}}"# + "\n"
    try Data((meta + RequestPayloads.codexQuestionCall + "\n").utf8).write(to: rollout)

    let watch = CodexQuestionWatch(
      sessionsDirectory: sessions, workingDirectoryPath: work, since: since,
      pollInterval: .milliseconds(20), discoveryTimeout: .seconds(2))
    var iterator = watch.signals().makeAsyncIterator()
    let first = await iterator.next()
    #expect(notice(of: first)?.key == "codex:call_1")
  }
}

@Suite("Answer keymaps")
struct AnswerKeymapTests {
  private let claude = ClaudeCodeAnswerKeymap()
  private let permission = AgentRequestContent.permission(
    AgentToolPermission(
      tool: .shell, toolName: "Bash", subject: "touch a",
      alwaysAllow: AgentAlwaysAllow(rules: [.mode("acceptEdits")], scope: .session)))

  @Test("Claude Code: 1 allows, 2 always allows when offered, Escape refuses")
  func claudePermission() {
    #expect(claude.keystrokes(for: .allowOnce, to: permission) == [[0x31]])
    #expect(claude.keystrokes(for: .allowAlways, to: permission) == [[0x32]])
    #expect(claude.keystrokes(for: .deny, to: permission) == [[0x1B]])
    let once = AgentRequestContent.permission(
      AgentToolPermission(tool: .shell, toolName: "Bash", subject: "touch a"))
    #expect(claude.answers(for: once) == [.allowOnce, .deny])
    #expect(claude.keystrokes(for: .allowAlways, to: once) == nil)
  }

  @Test("Claude Code: a digit per question, a free answer pasted, a review submitted")
  func claudeQuestions() {
    let tea = AgentQuestion(
      header: nil, text: "Tea?", options: [.init(label: "Tea"), .init(label: "Coffee")])
    let sugar = AgentQuestion(
      header: nil, text: "Sugar?", options: [.init(label: "Yes"), .init(label: "No")])
    #expect(
      claude.keystrokes(for: .answers([.option(1)]), to: .questions([tea])) == [[0x32]])
    #expect(
      claude.keystrokes(for: .answers([.text("Hot\u{1B}[201~ chocolate")]), to: .questions([tea]))
        == [[0x33], TerminalKeys.bracketedPaste("Hot[201~ chocolate"), [0x0D]])
    #expect(
      claude.keystrokes(for: .answers([.option(1), .option(0)]), to: .questions([tea, sugar]))
        == [[0x32], [0x31], [0x31]])
    #expect(claude.keystrokes(for: .answers([.option(5)]), to: .questions([tea])) == nil)
    #expect(claude.keystrokes(for: .answers([.text("  ")]), to: .questions([tea])) == nil)
    let toppings = AgentQuestion(
      header: nil, text: "Toppings?", options: [.init(label: "Ham")], allowsMultipleChoices: true)
    #expect(claude.answers(for: .questions([toppings])).isEmpty)
  }

  @Test("Claude Code: a plan is accepted with a digit, rejected with Escape")
  func claudePlan() {
    let plan = AgentRequestContent.plan(excerpt: "x", isComplete: true)
    #expect(claude.keystrokes(for: .approvePlan(.acceptEdits), to: plan) == [[0x31]])
    #expect(claude.keystrokes(for: .approvePlan(.reviewEdits), to: plan) == [[0x32]])
    #expect(claude.keystrokes(for: .rejectPlan, to: plan) == [[0x1B]])
    #expect(claude.answers(for: .elicitation).isEmpty)
  }

  @Test("Codex: y, p for a command, a for a patch, Escape; its questions stay in the terminal")
  func codex() {
    let codex = CodexAnswerKeymap()
    let command = AgentRequestContent.permission(
      AgentToolPermission(tool: .shell, toolName: "Bash", subject: "ls"))
    let patch = AgentRequestContent.permission(
      AgentToolPermission(tool: .patch, toolName: "apply_patch", subject: "a.txt"))
    #expect(codex.keystrokes(for: .allowOnce, to: command) == [Array("y".utf8)])
    #expect(codex.keystrokes(for: .allowAlways, to: command) == [Array("p".utf8)])
    #expect(codex.keystrokes(for: .allowAlways, to: patch) == [Array("a".utf8)])
    #expect(codex.keystrokes(for: .deny, to: patch) == [[0x1B]])
    #expect(codex.answers(for: .questions([])).isEmpty)
  }

  @Test("A pasted answer can neither close its paste nor send a control key")
  func paste() {
    let bytes = TerminalKeys.bracketedPaste("a\u{1B}[201~\u{03}b\nc\td")
    #expect(bytes == Array("\u{1B}[200~a[201~b\nc\td\u{1B}[201~".utf8))
  }
}

@Suite("The hook of a finishing tool")
struct ResolutionHookTests {
  @Test("It keeps which agent ran which tool on what, and the decoder reads it back")
  func roundTrip() throws {
    let log = try temporaryLog()
    let command = AgentActivityHookCommand.command(
      event: "PostToolUse", payload: .fields(AgentRequestReading.resolutionFields))
    let input =
      #"{"session_id":"s","agent_id":"a1","agent_type":"general-purpose","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo \"quoted\"","description":"d"},"tool_response":{"stdout":"quoted"},"tool_use_id":"t"}"#
    _ = try runHook(command, input: input, log: log)
    let payload = try #require(lines(of: log).first?.last)
    let decoder = ClaudeCodeSignalDecoder(makeInterruptionWatch: { _ in AsyncStream { _ in } })
    #expect(
      decoder.signal(for: event("PostToolUse", payload))
        == .toolFinished("Bash", agentID: "a1", subject: #"echo "quoted""#))
  }
}
