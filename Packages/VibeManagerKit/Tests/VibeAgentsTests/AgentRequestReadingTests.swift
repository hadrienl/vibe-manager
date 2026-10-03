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
  static let subAgentDone =
    #"{"agent_id":"a89e4f8137e913354","tool_name":"Bash","command":"touch a.txt"}"#
  static let question =
    #"{"session_id":"s","cwd":"/Users/a/dev","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Tea or coffee?","header":"Beverage","options":[{"label":"Tea","description":"Hot or cold tea"},{"label":"Coffee","description":"Your daily brew"}],"multiSelect":false}]},"tool_use_id":"toolu_1"}"#
  static let previewedQuestion =
    #"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Layout?","header":"Layout","options":[{"label":"Grid","preview":"┌─┬─┐\n│ │ │\n└─┴─┘"},{"label":"List","preview":" \n "}],"multiSelect":false},{"question":"Extras?","header":"Extras","options":[{"label":"Milk","preview":"(milk)"},{"label":"Sugar"}],"multiSelect":true}]}}"#
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

private func requestNotice(in signal: AgentSignal?) -> AgentRequestNotice? {
  if case .questionAsked(_, _, let notice) = signal { return notice }
  return nil
}

@Suite("Reading what an agent asks")
struct AgentRequestReadingTests {
  private let claude = ClaudeCodeSignalDecoder(makeInterruptionWatch: { _ in AsyncStream { _ in } })

  @Test("A permission names its tool, its exact command, and what always allowing would allow")
  func permission() throws {
    let notice = try #require(
      requestNotice(in: claude.signal(for: event("PermissionRequest", RequestPayloads.bash))))
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
        == AgentAlwaysAllow(
          rules: [.directories(["/Users/a/dev"]), .mode("acceptEdits")], scope: .session))
    #expect(notice.reference == AgentToolReference(tool: "Bash", subject: "touch hello.txt"))
  }

  @Test("A sub-agent's permission is told apart, and the tool it runs settles it")
  func subAgent() throws {
    let asked = try #require(
      requestNotice(
        in: claude.signal(for: event("PermissionRequest", RequestPayloads.subAgentBash))))
    #expect(asked.reference.agentID == "a89e4f8137e913354")
    let done = claude.signal(for: event("PostToolUse", RequestPayloads.subAgentDone))
    #expect(
      done == .toolFinished("Bash", agentID: "a89e4f8137e913354", subject: "touch a.txt"))
    #expect(
      asked.reference.match(
        AgentToolReference(tool: "Bash", agentID: "a89e4f8137e913354", subject: "touch a.txt"))
        == .same)
  }

  @Test("A question is announced before its dialog is drawn, with its options")
  func question() throws {
    let announced = try #require(
      requestNotice(in: claude.signal(for: event("PreToolUse", RequestPayloads.question))))
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
      requestNotice(
        in: claude.signal(
          for: event(
            "PermissionRequest",
            RequestPayloads.question.replacingOccurrences(
              of: "PreToolUse", with: "PermissionRequest")))))
    #expect(shown.isShown)
    #expect(shown.reference.match(announced.reference) == .same)
  }

  @Test("An option's preview is kept, a blank one is not; beside previews, no answer of one's own")
  func previewedQuestion() throws {
    let notice = try #require(
      requestNotice(
        in: claude.signal(for: event("PermissionRequest", RequestPayloads.previewedQuestion))))
    guard case .questions(let questions) = notice.content else {
      Issue.record("no questions")
      return
    }
    #expect(questions[0].options.map(\.preview) == ["┌─┬─┐\n│ │ │\n└─┴─┘", nil])
    #expect(questions[0].showsPreviews)
    #expect(!questions[0].allowsFreeText)
    // Boxes to tick are drawn as always, previews or not.
    #expect(questions[1].options.map(\.preview) == ["(milk)", nil])
    #expect(!questions[1].showsPreviews)
    #expect(questions[1].allowsFreeText)
  }

  @Test("One preview at a time: the option pointed at, else the one chosen, else the first")
  func previewedOption() {
    let layout = AgentQuestion(
      header: nil, text: "Layout?",
      options: [.init(label: "Grid"), .init(label: "List", preview: "≡"), .init(label: "Cards")])
    #expect(layout.previewedOption(highlighted: nil, chosen: nil) == 1)
    #expect(layout.previewedOption(highlighted: nil, chosen: 2) == 2)
    #expect(layout.previewedOption(highlighted: 0, chosen: 2) == 0)
    #expect(layout.previewedOption(highlighted: 7, chosen: nil) == 1)
    let plain = AgentQuestion(header: nil, text: "Tea?", options: [.init(label: "Tea")])
    #expect(plain.previewedOption(highlighted: 0, chosen: 0) == nil)
  }

  @Test("A plan, an MCP call, a cut-short report")
  func others() throws {
    let plan = try #require(
      requestNotice(in: claude.signal(for: event("PermissionRequest", RequestPayloads.plan))))
    #expect(
      plan.content == .plan(excerpt: "## Plan\n- Create plan.txt with Write.", isComplete: true))

    let mcp = try #require(
      requestNotice(in: claude.signal(for: event("PermissionRequest", RequestPayloads.mcp))))
    guard case .permission(let permission) = mcp.content else {
      Issue.record("not a permission")
      return
    }
    #expect(permission.tool == .mcp(server: "github", tool: "create_issue"))
    #expect(permission.details?.contains("It breaks") == true)

    let cut = String(RequestPayloads.bash.prefix(300))
    let truncated = try #require(
      requestNotice(in: claude.signal(for: event("PermissionRequest", cut))))
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
      requestNotice(in: decoder.signal(for: event("PermissionRequest", RequestPayloads.codexBash))))
    guard case .permission(let command) = bash.content else {
      Issue.record("not a permission")
      return
    }
    #expect(command.subject == "touch hello.txt")
    #expect(command.alwaysAllow == AgentAlwaysAllow(rules: [.commandPrefix], scope: .session))

    let patch = try #require(
      requestNotice(in: decoder.signal(for: event("PermissionRequest", RequestPayloads.codexPatch)))
    )
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
    let notice = try #require(asked.first.flatMap(requestNotice(in:)))
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
    // One question answered long ago, one still waiting: only the second is said.
    let waiting = RequestPayloads.codexQuestionCall.replacingOccurrences(
      of: "call_1", with: "call_3")
    let history = [
      meta, RequestPayloads.codexQuestionCall, RequestPayloads.codexQuestionOutput, waiting,
    ].joined(separator: "\n")
    try Data((history + "\n").utf8).write(to: rollout)

    let watch = CodexQuestionWatch(
      sessionsDirectory: sessions, workingDirectoryPath: work, since: since,
      discoveryInterval: .milliseconds(20), discoveryTimeout: .seconds(2))
    var iterator = watch.signals().makeAsyncIterator()
    let first = await iterator.next()
    #expect(requestNotice(in: first)?.key == "codex:call_3")

    // Then what the session writes next, as it comes.
    let handle = try FileHandle(forWritingTo: rollout)
    try handle.seekToEnd()
    try handle.write(
      contentsOf: Data(
        (RequestPayloads.codexQuestionOutput.replacingOccurrences(
          of: "call_1", with: "call_3") + "\n").utf8))
    try handle.close()
    #expect(await iterator.next() == .toolFinished("request_user_input", subject: "call_3"))
  }
}

@Suite("Answer keymaps")
struct AnswerKeymapTests {
  private let claude = ClaudeCodeAnswerKeymap()
  private let permission = AgentRequestContent.permission(
    AgentToolPermission(
      tool: .shell, toolName: "Bash", subject: "touch a",
      alwaysAllow: AgentAlwaysAllow(rules: [.mode("acceptEdits")], scope: .session)))

  @Test("Claude Code: Yes allows, Yes and always allows when offered, Escape refuses")
  func claudePermission() {
    let screen = DialogScreens.dialog(DialogScreens.claudeBash)
    #expect(claude.keystrokes(for: .allowOnce, to: permission, screen: screen) == [[0x31]])
    #expect(claude.keystrokes(for: .allowAlways, to: permission, screen: screen) == [[0x32]])
    #expect(claude.keystrokes(for: .deny, to: permission) == [[0x1B]])
    let once = AgentRequestContent.permission(
      AgentToolPermission(tool: .shell, toolName: "Bash", subject: "touch a"))
    #expect(claude.answers(for: once) == [.allowOnce, .deny])
    #expect(claude.keystrokes(for: .allowAlways, to: once, screen: screen) == nil)
  }

  @Test("Claude Code: a digit per question, a free answer pasted, a review submitted")
  func claudeQuestions() {
    // The dialog of the first question, as Claude Code draws it (#273): its options, then
    // "Type something." when an answer of one's own is offered.
    func keys(_ answer: AgentAnswer, _ questions: [AgentQuestion]) -> [[UInt8]]? {
      let first = questions[0]
      let labels = first.options.map(\.label) + (first.allowsFreeText ? ["Type something."] : [])
      let screen = AgentDialogScreen(
        options: labels.enumerated().map { .init(number: $0 + 1, label: $1) })
      return claude.keystrokes(for: answer, to: .questions(questions), screen: screen)
    }
    let tea = AgentQuestion(
      header: nil, text: "Tea?", options: [.init(label: "Tea"), .init(label: "Coffee")])
    let sugar = AgentQuestion(
      header: nil, text: "Sugar?", options: [.init(label: "Yes"), .init(label: "No")])
    #expect(
      keys(.answers([.option(1)]), [tea]) == [[0x32]])
    #expect(
      keys(.answers([.text("Hot\u{1B}[201~ chocolate")]), [tea])
        == [[0x33], TerminalKeys.bracketedPaste("Hot[201~ chocolate"), [0x0D]])
    #expect(
      keys(.answers([.option(1), .option(0)]), [tea, sugar])
        == [[0x32], [0x31], [0x31]])
    #expect(keys(.answers([.option(5)]), [tea]) == nil)
    #expect(keys(.answers([.text("  ")]), [tea]) == nil)
    // Boxes, as drawn by 2.1.283: each digit ticks one, the right arrow moves on, and the review
    // that follows is submitted with 1.
    let toppings = AgentQuestion(
      header: nil, text: "Toppings?", options: [.init(label: "Ham"), .init(label: "Olives")],
      allowsMultipleChoices: true)
    #expect(claude.answers(for: .questions([toppings])).contains(.chooseOptions))
    #expect(
      keys(.answers([.options([1, 0])]), [toppings])
        == [[0x31], [0x32], TerminalKeys.rightArrow, [0x31]])
    #expect(
      keys(.answers([.option(1), .options([0])]), [tea, toppings])
        == [[0x32], [0x31], TerminalKeys.rightArrow, [0x31]])
    #expect(
      keys(.answers([.options([1]), .option(0)]), [toppings, tea])
        == [[0x32], TerminalKeys.rightArrow, [0x31], [0x31]])
    #expect(keys(.answers([.options([])]), [toppings]) == nil)
    #expect(keys(.answers([.text("Cheese")]), [toppings]) == nil)
    // Beside previews, as drawn by 2.1.285, a digit only moves the highlight: Return takes it.
    let layout = AgentQuestion(
      header: nil, text: "Layout?",
      options: [.init(label: "Grid", preview: "▦"), .init(label: "List")],
      allowsFreeText: false)
    #expect(
      keys(.answers([.option(1)]), [layout]) == [[0x32], [0x0D]])
    #expect(
      keys(.answers([.option(0), .option(1)]), [layout, tea])
        == [[0x31], [0x0D], [0x32], [0x31]])
    #expect(keys(.answers([.text("Cards")]), [layout]) == nil)
  }

  @Test("Claude Code: a plan is accepted with the digit of its option, rejected with Escape")
  func claudePlan() {
    let plan = AgentRequestContent.plan(excerpt: "x", isComplete: true)
    let screen = DialogScreens.dialog(DialogScreens.claudePlanEdits)
    #expect(
      claude.keystrokes(for: .approvePlan(.acceptEdits), to: plan, screen: screen) == [[0x31]])
    #expect(
      claude.keystrokes(for: .approvePlan(.reviewEdits), to: plan, screen: screen) == [[0x32]])
    #expect(claude.keystrokes(for: .rejectPlan, to: plan) == [[0x1B]])
    #expect(claude.answers(for: .elicitation(AgentElicitation())).isEmpty)
  }

  @Test("Codex: y, p for a command, a for a patch, Escape; its questions stay in the terminal")
  func codex() {
    let codex = CodexAnswerKeymap()
    let command = AgentRequestContent.permission(
      AgentToolPermission(
        tool: .shell, toolName: "Bash", subject: "ls",
        alwaysAllow: CodexAnswerKeymap.alwaysAllow(for: "Bash")))
    let patch = AgentRequestContent.permission(
      AgentToolPermission(
        tool: .patch, toolName: "apply_patch", subject: "a.txt",
        alwaysAllow: CodexAnswerKeymap.alwaysAllow(for: "apply_patch")))
    let screen = DialogScreens.dialog(DialogScreens.codexCommand)
    #expect(codex.keystrokes(for: .allowOnce, to: command, screen: screen) == [Array("y".utf8)])
    #expect(codex.keystrokes(for: .allowAlways, to: command, screen: screen) == [Array("p".utf8)])
    let patchScreen = DialogScreens.dialog(
      """
      › 1. Yes, proceed (y)
        2. Yes, and don't ask again for these files (a)
        3. No, and tell Codex what to do differently (esc)
      """)
    #expect(
      codex.keystrokes(for: .allowAlways, to: patch, screen: patchScreen) == [Array("a".utf8)])
    #expect(codex.keystrokes(for: .deny, to: patch) == [[0x1B]])
    #expect(codex.answers(for: .questions([])).isEmpty)
  }

  @Test("Codex: a tool of an MCP server is allowed with its form's first option, `y` it ignores")
  func codexMCPTool() {
    let codex = CodexAnswerKeymap()
    let tool = AgentRequestContent.permission(
      AgentRequestReading.permission(
        toolName: "mcp__prisme_ai_builder__call_api", input: ["path": "/me"],
        workingDirectory: nil, alwaysAllow: CodexAnswerKeymap.alwaysAllow(for: "mcp__x__y")))
    #expect(codex.answers(for: tool) == [.allowOnce, .deny])
    let screen = DialogScreens.dialog(DialogScreens.codexMCPTool)
    #expect(codex.keystrokes(for: .allowOnce, to: tool, screen: screen) == [Array("1".utf8)])
    #expect(codex.keystrokes(for: .allowAlways, to: tool) == nil)
    #expect(codex.keystrokes(for: .deny, to: tool) == [[0x1B]])
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
