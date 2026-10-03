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
    guard
      case .elicitation(let elicitation) = notice(of: ClaudeCodeSignalDecoder().signal(for: event))?
        .content
    else { return nil }
    return elicitation
  }

  @Test("A page to open keeps the server, its words and the address")
  func url() throws {
    let read = try #require(
      elicitation(try reported(mode: "url", url: "https://example.org/a?b=1")))
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
  static let turnComplete =
    #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t"}}"#

  @Test("Asked with its titles and suggested answers; taken, not answered; gone with the turn")
  func lifecycle() throws {
    var pending: Set<String> = []
    let asked = CodexQuestionWatch.signals(in: Data(Self.call.utf8), pending: &pending)
    let notice = try #require(notice(of: asked.first))
    #expect(notice.key == "codex:call_a")
    #expect(
      notice.reference == AgentToolReference(tool: "request_user_input_async", subject: "call_a"))
    #expect(
      notice.content
        == .questions([
          AgentQuestion(
            header: nil, text: "Which port?", options: [.init(label: "8080"), .init(label: "3000")]),
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
    try Data(
      ([Self.call, Self.accepted, Self.turnComplete, later].joined(separator: "\n") + "\n").utf8
    )
    .write(to: rollout)
    let (pending, waiting, _) = CodexQuestionWatch.unanswered(in: rollout)
    #expect(pending == ["async:call_b"])
    #expect(waiting.compactMap { notice(of: $0)?.key } == ["codex:call_b"])
  }
}

@Suite("Codex's request_permissions and write_stdin (#273, P3)")
struct CodexPermissionsReadingTests {
  /// From `tui/src/bottom_pane/snapshots` in 0.159.2: the dialog of `request_permissions`.
  static let grantDialog = """
      Would you like to grant these permissions?

      Reason: need workspace access

      Permission rule: network; read `/tmp/readme.txt`; write `/tmp/out.txt`

    › 1. Yes, grant these permissions for this turn (y)
      2. Yes, grant for this turn with strict auto review (r)
      3. Yes, grant these permissions for this session (a)
      4. No, continue without permissions (d)

      Press enter to confirm or esc to cancel
    """
  /// The dialog of `write_stdin`: `Approved` and `Abort` only.
  static let inputDialog = """
      Would you like to send input to terminal 42?
      Input: "confirm\\n"
    › 1. Yes, proceed (y)
      2. No, and tell Codex what to do differently (esc)
      Press enter to confirm or esc to cancel
    """

  private func permission(_ payload: String) throws -> AgentToolPermission {
    let signal = CodexSignalDecoder().signal(for: event("PermissionRequest", payload))
    guard case .permission(let permission) = notice(of: signal)?.content else {
      throw CancellationError()
    }
    return permission
  }

  @Test("The permissions asked for read as Codex words them, two lists or entries")
  func grant() throws {
    let legacy = try permission(
      #"{"tool_name":"request_permissions","tool_input":{"reason":"need workspace access","permissions":{"network":{"enabled":true},"file_system":{"read":["/tmp/readme.txt"],"write":["/tmp/out.txt"]}}}}"#
    )
    #expect(legacy.tool == .grant)
    #expect(legacy.subject == "network; read /tmp/readme.txt; write /tmp/out.txt")
    #expect(legacy.purpose == "need workspace access")
    #expect(legacy.alwaysAllow == AgentAlwaysAllow(rules: [.permissions], scope: .session))
    let entries = try permission(
      #"{"tool_name":"request_permissions","tool_input":{"reason":null,"permissions":{"file_system":{"entries":[{"path":{"type":"path","path":"/a"},"access":"write"},{"path":{"type":"glob_pattern","pattern":"**/.env"},"access":"deny"}]}}}}"#
    )
    #expect(entries.subject == "write /a; deny read glob **/.env")
    #expect(entries.purpose == nil)
  }

  @Test("Input for a terminal shows what would be typed")
  func input() throws {
    let input = try permission(
      #"{"tool_name":"write_stdin","tool_input":{"session_id":42,"chars":"confirm\n","cwd":"/tmp"}}"#
    )
    #expect(input.tool == .terminalInput)
    #expect(input.subject == "confirm\n")
    #expect(input.alwaysAllow == nil)
  }

  @Test("Granted for the turn by y, the session by a, refused by d — never by Escape")
  func grantKeys() throws {
    let keymap = CodexAnswerKeymap()
    let content = AgentRequestContent.permission(
      try permission(
        #"{"tool_name":"request_permissions","tool_input":{"permissions":{"network":{"enabled":true}}}}"#
      ))
    let screen = AgentDialogScreen(screen: Self.grantDialog)
    #expect(keymap.answers(for: content) == [.allowOnce, .allowAlways, .deny])
    #expect(keymap.keystrokes(for: .allowOnce, to: content, screen: screen) == [Array("y".utf8)])
    #expect(keymap.keystrokes(for: .allowAlways, to: content, screen: screen) == [Array("a".utf8)])
    #expect(keymap.keystrokes(for: .deny, to: content, screen: screen) == [Array("d".utf8)])
    // Some other dialog on screen: nothing is typed.
    let other = AgentDialogScreen(screen: Self.inputDialog)
    #expect(keymap.keystrokes(for: .deny, to: content, screen: other) == nil)
    #expect(keymap.keystrokes(for: .deny, to: content, screen: nil) == nil)
  }

  @Test("Input for a terminal is sent once or refused, never always")
  func inputKeys() throws {
    let keymap = CodexAnswerKeymap()
    let content = AgentRequestContent.permission(
      try permission(#"{"tool_name":"write_stdin","tool_input":{"session_id":42,"chars":"y"}}"#))
    let screen = AgentDialogScreen(screen: Self.inputDialog)
    #expect(keymap.answers(for: content) == [.allowOnce, .deny])
    #expect(keymap.keystrokes(for: .allowOnce, to: content, screen: screen) == [Array("y".utf8)])
    #expect(keymap.keystrokes(for: .deny, to: content, screen: screen) == [TerminalKeys.escape])
  }
}

/// Claude Code 2.1.288's question dialogs, drawn in a pty and replayed (#273, P3).
enum QuestionScreens {
  static let single = """
    ⏺  Colour

    Which colour?

    ❯ 1. Red
         Vibrant and energetic, evokes passion and warmth
      2. Green
         Calm and refreshing, associated with nature and growth
      3. Blue
         Cool and serene, inspires trust and tranquility
      4. Type something.
    ────────────────────────────────────────────────────────────────────────────────────────────────────
      5. Chat about this

    Enter to select · ↑/↓ to navigate · Esc to cancel
    """
  static let multiple = """
    ⏺  ☐ Toppings  ✔ Submit  →

    Which toppings?

    ❯ 1. [ ] Cheese
             Melted mozzarella cheese
      2. [ ] Ham
             Sliced ham
      3. [ ] Olives
             Black olives
      4. [ ] Type something
         Submit
    ────────────────────────────────────────────────────────────────────────────────────────────────────
      5. Chat about this

    Enter to select · ↑/↓ to navigate · Esc to cancel
    """
  static let previews = """
     ☐ Layout

    Which layout?

    ❯ 1. Grid                         ┌──────────────────────────────────────────┐
      2. List                         │ [Item] [Item]                            │
                                      │ [Item] [Item]                            │
                                      │ [Item] [Item]                            │
                                      └──────────────────────────────────────────┘

                                      Notes: press n to add notes

    ────────────────────────────────────────────────────────────────────────────────────────────────────
      Chat about this

    Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel
    """
}

@Suite("Claude Code's questions answered by the digits on screen (#273, P3)")
struct QuestionScreenKeymapTests {
  let keymap = ClaudeCodeAnswerKeymap()

  private func colours(_ labels: [String] = ["Red", "Green", "Blue"]) -> AgentRequestContent {
    .questions([
      AgentQuestion(
        header: "Colour", text: "Which colour?", options: labels.map { .init(label: $0) })
    ])
  }

  @Test("Options set apart by a rule are still one dialog")
  func rule() throws {
    let single = try #require(AgentDialogScreen(screen: QuestionScreens.single))
    #expect(single.options.map(\.number) == [1, 2, 3, 4, 5])
    #expect(single.options[4].label == "Chat about this")
    let multiple = try #require(AgentDialogScreen(screen: QuestionScreens.multiple))
    #expect(multiple.options.map(\.number) == [1, 2, 3, 4, 5])
  }

  @Test("The question on screen is answered by its digits, an answer of one's own included")
  func drawn() {
    let screen = AgentDialogScreen(screen: QuestionScreens.single)
    #expect(
      keymap.keystrokes(for: .answers([.option(1)]), to: colours(), screen: screen) == [
        Array("2".utf8)
      ])
    #expect(
      keymap.keystrokes(for: .answers([.text("Teal")]), to: colours(), screen: screen)
        == [Array("4".utf8), TerminalKeys.bracketedPaste("Teal"), TerminalKeys.enter])
  }

  @Test("Another question on screen, its options moved, or none read: nothing is typed")
  func notDrawn() {
    let screen = AgentDialogScreen(screen: QuestionScreens.single)
    #expect(
      keymap.keystrokes(
        for: .answers([.option(0)]), to: colours(["Green", "Red", "Blue"]), screen: screen) == nil)
    #expect(
      keymap.keystrokes(for: .answers([.option(0)]), to: colours(["Red", "Green"]), screen: screen)
        == nil)
    #expect(keymap.keystrokes(for: .answers([.option(0)]), to: colours(), screen: nil) == nil)
  }

  @Test("Boxes and previews drawn beside the options do not hide them")
  func boxesAndPreviews() {
    let toppings = AgentRequestContent.questions([
      AgentQuestion(
        header: nil, text: "Which toppings?",
        options: [.init(label: "Cheese"), .init(label: "Ham"), .init(label: "Olives")],
        allowsMultipleChoices: true)
    ])
    #expect(
      keymap.keystrokes(
        for: .answers([.options([0, 2])]), to: toppings,
        screen: AgentDialogScreen(screen: QuestionScreens.multiple))
        == [Array("1".utf8), Array("3".utf8), TerminalKeys.rightArrow, Array("1".utf8)])
    let layout = AgentRequestContent.questions([
      AgentQuestion(
        header: nil, text: "Which layout?",
        options: [
          .init(label: "Grid", preview: "[Item]"), .init(label: "List", preview: "[Item 1]"),
        ],
        allowsFreeText: false)
    ])
    #expect(
      keymap.keystrokes(
        for: .answers([.option(1)]), to: layout,
        screen: AgentDialogScreen(screen: QuestionScreens.previews))
        == [Array("2".utf8), TerminalKeys.enter])
  }
}

@Suite("Codex's hooks of its stopping, within its timeout (#273, P3)")
struct CodexStoppingTimeoutTests {
  @Test("Interrupt and SessionEnd ask for the three seconds Codex gives, the others for five")
  func timeouts() {
    let options = CodexActivityHooks.options().filter { $0 != "-c" }
    for option in options {
      let isStopping = option.hasPrefix("hooks.Interrupt=") || option.hasPrefix("hooks.SessionEnd=")
      #expect(option.contains(isStopping ? "timeout=3," : "timeout=5,"), "\(option.prefix(40))")
    }
    #expect(options.count == CodexActivityHooks.hooks.count)
  }
}
