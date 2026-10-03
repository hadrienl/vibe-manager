import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private let session = SessionID()
private let start = Date(timeIntervalSince1970: 4_000_000)

private func context(_ key: String, at seconds: TimeInterval = 0) -> AgentActivityContext {
  AgentActivityContext(
    now: start.addingTimeInterval(seconds), isVisible: false, approvalAnswerKeys: [[0x31], [0x0D]],
    requestID: AgentRequestID(sessionID: session, key: key))
}

private func feed(_ signals: AgentSignal..., to state: AgentActivityState? = nil)
  -> AgentActivityState
{
  var state = state ?? AgentActivityState(activity: .working, source: .structured)
  for (index, signal) in signals.enumerated() {
    state = AgentActivityMachine.reduce(
      state, .signal(signal), context: context("l\(index)-\(signal)", at: TimeInterval(index)))
  }
  return state
}

private let network = AgentSignal.dialogAnnounced(
  AgentTerminalPrompt(kind: .network, message: "A sandboxed command needs network access"))

private func permission(shown: Bool, command: String = "ls", agent: String? = nil) -> AgentSignal {
  .questionAsked(
    .approval, tool: "Bash",
    notice: AgentRequestNotice(
      content: .permission(AgentToolPermission(tool: .shell, toolName: "Bash", subject: command)),
      reference: AgentToolReference(tool: "Bash", agentID: agent, subject: command),
      isShown: shown))
}

@Suite("Dialogs the CLI only announces (#273)")
struct AnnouncedDialogTests {
  @Test("With nothing waiting, an announced dialog is a request, answered in the terminal")
  func queued() {
    let state = feed(network)
    #expect(state.activity == .awaitingUser(.approval))
    #expect(
      state.requests.map(\.content) == [
        .inTerminal(
          AgentTerminalPrompt(kind: .network, message: "A sandboxed command needs network access"))
      ])
    #expect(state.answering(state.requests[0], keymap: nil) == .inTerminalOnly(.notSupported))
  }

  @Test("Behind a drawn request, the announcement repeats it: nothing more is queued")
  func repeatsADrawnRequest() {
    let state = feed(permission(shown: true), network)
    #expect(state.requests.count == 1)
    #expect(!state.requests[0].content.isAnnouncedOnly)
  }

  @Test("A question never known drawn is not announced twice")
  func questionAlreadyRead() {
    let question = AgentSignal.questionAsked(
      .question,
      notice: AgentRequestNotice(
        content: .questions([AgentQuestion(header: nil, text: "Tea?", options: [])]),
        reference: AgentToolReference(tool: "request_user_input"), isShown: false))
    let state = feed(
      question, .dialogAnnounced(AgentTerminalPrompt(kind: .question, message: "Tea?")))
    #expect(state.requests.count == 1)
  }

  @Test(
    "The main agent's turn or prompt takes the announced dialog away",
    arguments: [
      AgentSignal.promptSubmitted(byUser: true), .turnEnded, .interrupted, .questionResolved,
    ])
  func settledBy(_ signal: AgentSignal) {
    let state = feed(network, signal)
    #expect(state.requests.isEmpty)
    #expect(state.activity != .awaitingUser(.approval))
  }

  @Test("A tool ending — another one, run beside it — or a task resuming the agent leaves it up")
  func notSettledByOtherTools() {
    let state = feed(
      network, .toolFinished("Bash"), .toolFinished("Bash", agentID: "a1"),
      .promptSubmitted(byUser: false))
    #expect(state.requests.count == 1)
    #expect(state.activity == .awaitingUser(.approval))
  }

  @Test("A plan or a question announced as the turn ends outlives the end's report")
  func drawnAtTheEnd() {
    let plan = AgentSignal.dialogAnnounced(
      AgentTerminalPrompt(kind: .plan, message: "Plan mode prompt: Implement this plan?"))
    let state = feed(plan, .turnEnded)
    #expect(state.requests.first?.content.isAnnouncedOnly == true)
    #expect(state.activity == .awaitingUser(.approval))
    #expect(feed(.promptSubmitted(byUser: true), to: state).requests.isEmpty)
  }

  @Test("A key that answers dialogs, typed in the terminal, is its answer")
  func answeredInTheTerminal() {
    let state = feed(network)
    let typed = AgentActivityMachine.reduce(state, .userInput([0x31]), context: context("k"))
    #expect(typed.requests.isEmpty)
    let other = AgentActivityMachine.reduce(state, .userInput([0x61]), context: context("k"))
    #expect(other.requests.count == 1)
  }

  @Test("A request reported next replaces the announcement, which is behind the agent")
  func replacedByAReport() {
    let state = feed(network, permission(shown: true))
    #expect(state.requests.count == 1)
    #expect(!state.requests[0].content.isAnnouncedOnly)
  }

  @Test("A sub-agent's question leaves the main agent's announced dialog up")
  func subagentQuestion() {
    let state = feed(network, permission(shown: false, agent: "a1"))
    #expect(state.requests.first?.content.isAnnouncedOnly == true)
  }

  @Test("A form, a question or a plan announced is ended by Return or Escape, not by its letters")
  func formKeys() {
    let form = feed(.dialogAnnounced(AgentTerminalPrompt(kind: .form, message: "Server")))
    let typed = AgentActivityMachine.reduce(form, .userInput([0x31]), context: context("k"))
    #expect(typed.requests.count == 1)
    let sent = AgentActivityMachine.reduce(form, .userInput([0x0D]), context: context("k"))
    #expect(sent.requests.isEmpty)
  }

  @Test("Codex's form for an MCP tool puts the permission it reported in doubt, adding nothing")
  func codexMCPTool() {
    let form = AgentSignal.dialogDrawn(
      AgentDrawnDialog(.server("prisme-ai-builder")),
      otherwise: AgentTerminalPrompt(
        kind: .form, message: "Approval requested by prisme-ai-builder"))
    let tool = AgentSignal.questionAsked(
      .approval, tool: "mcp__prisme_ai_builder__call_api",
      notice: AgentRequestNotice(
        content: .permission(
          AgentToolPermission(
            tool: .mcp(server: "prisme_ai_builder", tool: "call_api"),
            toolName: "mcp__prisme_ai_builder__call_api", subject: nil)),
        reference: AgentToolReference(tool: "mcp__prisme_ai_builder__call_api"), isShown: false))
    let state = feed(tool, form)
    #expect(state.requests.count == 1)
    // A server's name may be another of its tools' (#280): answered in the session.
    #expect(!state.requests[0].isShown)
    #expect(state.isFirstRequestUncertain)
    // A server's own form, no permission of it waiting: a request answered in the terminal.
    let own = feed(form)
    #expect(own.requests.first?.content.isAnnouncedOnly == true)
  }

  @Test("A dialog arms only the request it names: an older one settled with no dialog is dropped")
  func stale() {
    // `ls` was settled by Codex's automatic review, with no dialog and no report of it.
    let stale = feed(permission(shown: false, command: "ls"))
    let drawnB = AgentSignal.dialogDrawn(AgentDrawnDialog(.command("rm x")))
    // B's dialog read before B's report: `ls` is not armed in its place.
    let early = feed(drawnB, to: stale)
    #expect(!early.requests[0].isShown)
    let reported = AgentActivityMachine.reduce(
      early, .signal(permission(shown: false, command: "rm x")), context: context("b", at: 60))
    #expect(reported.requests.map(\.reference.subject) == ["rm x"])
    #expect(reported.requests[0].isShown)
    #expect(!reported.isFirstRequestUncertain)
    // B's report read first: B is armed, `ls` goes.
    let later = feed(permission(shown: false, command: "rm x"), drawnB, to: stale)
    #expect(later.requests.map(\.reference.subject) == ["rm x"])
    #expect(later.requests[0].isShown)
  }

  @Test("A dialog said drawn is forgotten once something says it was answered")
  func drawnThenAnswered() {
    let drawn = feed(.dialogDrawn(AgentDrawnDialog(.command("ls"))))
    for gone in [AgentSignal.questionResolved, .turnEnded, .promptSubmitted(byUser: true)] {
      let answered = AgentActivityMachine.reduce(drawn, .signal(gone), context: context("gone"))
      let reported = AgentActivityMachine.reduce(
        answered, .signal(permission(shown: false)), context: context("late", at: 60))
      #expect(!reported.requests[0].isShown)
    }
    let typed = AgentActivityMachine.reduce(drawn, .userInput([0x31]), context: context("key"))
    let reported = AgentActivityMachine.reduce(
      typed, .signal(permission(shown: false)), context: context("late", at: 60))
    #expect(!reported.requests[0].isShown)
  }

  @Test("Codex's word that a command quoted whole is drawn arms the permission it reported")
  func drawn() {
    let reported = feed(permission(shown: false))
    #expect(!reported.requests[0].isShown)
    let drawn = feed(.dialogDrawn(AgentDrawnDialog(.command("ls"))), to: reported)
    #expect(drawn.requests[0].isShown)
    // Another command's dialog does not arm it.
    #expect(!feed(.dialogDrawn(AgentDrawnDialog(.command("rm"))), to: reported).requests[0].isShown)
    // Quoted cut short, it may be another's: in doubt, not armed (#280).
    let cut = feed(.dialogDrawn(AgentDrawnDialog(.commandStart("l"))), to: reported)
    #expect(!cut.requests[0].isShown)
    #expect(cut.isFirstRequestUncertain)
    // Never drawn — its automatic review settled it — it is gone with the turn.
    #expect(feed(.turnEnded, to: reported).requests.isEmpty)
  }
}

/// Answers every request from the palette, to tell what `answering` lets through.
private struct PaletteKeymap: AgentAnswerKeymap {
  func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind> {
    [.allowOnce, .deny]
  }

  func keystrokes(
    for answer: AgentAnswer, to content: AgentRequestContent, screen: AgentDialogScreen?
  ) -> [[UInt8]]? {
    [[0x79]]
  }
}

@Suite("Only a command quoted whole arms a Codex permission (#280)")
struct PartlyQuotedDialogTests {
  /// Each signal at its own time, in seconds: requests a minute apart put nothing in doubt.
  private func play(
    _ steps: (TimeInterval, AgentSignal)..., to state: AgentActivityState? = nil
  ) -> AgentActivityState {
    var state = state ?? AgentActivityState(activity: .working, source: .structured)
    for (seconds, signal) in steps {
      state = AgentActivityMachine.reduce(
        state, .signal(signal), context: context("t\(seconds)", at: seconds))
    }
    return state
  }

  private func drawn(_ subject: AgentDrawnDialog.Subject) -> AgentSignal {
    .dialogDrawn(AgentDrawnDialog(subject))
  }

  private func patch(_ files: String) -> AgentSignal {
    .questionAsked(
      .approval, tool: "apply_patch",
      notice: AgentRequestNotice(
        content: .permission(
          AgentToolPermission(tool: .patch, toolName: "apply_patch", subject: files)),
        reference: AgentToolReference(tool: "apply_patch", subject: files), isShown: false))
  }

  private func mcp(_ tool: String) -> AgentSignal {
    let name = "mcp__github__\(tool)"
    return .questionAsked(
      .approval, tool: name,
      notice: AgentRequestNotice(
        content: .permission(
          AgentToolPermission(
            tool: .mcp(server: "github", tool: tool), toolName: name, subject: nil)),
        reference: AgentToolReference(tool: name), isShown: false))
  }

  /// Whether any card of `state` would answer from the palette.
  private func answersFromPalette(_ state: AgentActivityState) -> Bool {
    state.requests.contains {
      if case .fromPalette = state.answering($0, keymap: PaletteKeymap()) { return true }
      return false
    }
  }

  private let commandA = "npm run test -- a"
  private let commandB = "npm run test -- b"

  @Test(
    "A dialog quoted in part arms nothing, even alone: its card says to answer in the session",
    arguments: [
      (AgentDrawnDialog.Subject.commandStart("npm run test"), "command"),
      (.file("Model.swift"), "file"), (.files, "files"), (.server("github"), "server"),
    ])
  func partlyQuoted(subject: AgentDrawnDialog.Subject, kind: String) {
    let request: AgentSignal =
      switch kind {
      case "command": permission(shown: false, command: commandA)
      case "server": mcp("create_issue")
      default: patch("App/Model.swift\nApp/Other.swift")
      }
    let state = play((0, request), (60, drawn(subject)))
    #expect(state.requests.count == 1)
    #expect(!state.requests[0].isShown)
    #expect(
      state.answering(state.requests[0], keymap: PaletteKeymap()) == .inTerminalOnly(.uncertain))
    #expect(!answersFromPalette(state))
  }

  @Test("Two commands with the quoted start: neither is armed nor taken away, nothing answered")
  func commandStart() {
    let state = play(
      (0, permission(shown: false, command: commandA)),
      (60, permission(shown: false, command: commandB)),
      (120, drawn(.commandStart("npm run test"))))
    #expect(state.requests.map(\.reference.subject) == [commandA, commandB])
    #expect(state.requests.allSatisfy { !$0.isShown })
    let keymap = PaletteKeymap()
    #expect(state.answering(state.requests[0], keymap: keymap) == .inTerminalOnly(.uncertain))
    #expect(state.answering(state.requests[1], keymap: keymap) == .inTerminalOnly(.queued))
    #expect(!answersFromPalette(state))
  }

  @Test("A click before the other request is reported sends nothing: its dialog was quoted in part")
  func clickBeforeTheOtherReport() {
    // A was settled by Codex's automatic review, with no dialog; it waits for its tool to end.
    // B's dialog is drawn, its word read before B's report: only A fits it yet.
    let early = play(
      (0, permission(shown: false, command: commandA)), (60, drawn(.commandStart("npm run test"))))
    #expect(!early.requests[0].isShown)
    #expect(!answersFromPalette(early))
    // B's report, however soon or late, changes nothing.
    for seconds in [62.0, 600] {
      let reported = play((seconds, permission(shown: false, command: commandB)), to: early)
      #expect(reported.requests.map(\.reference.subject) == [commandA, commandB])
      #expect(reported.requests.allSatisfy { !$0.isShown })
      #expect(!answersFromPalette(reported))
    }
  }

  @Test("A command quoted whole, read before its report, arms it once reported, however late")
  func wholeBeforeItsReport() {
    let state = play(
      (0, permission(shown: false, command: commandA)), (60, drawn(.command(commandB))),
      (600, permission(shown: false, command: commandB)))
    // A, reported before it and never drawn, was settled with no dialog.
    #expect(state.requests.map(\.reference.subject) == [commandB])
    #expect(state.requests[0].isShown)
    #expect(answersFromPalette(state))
  }

  @Test("A command quoted whole is that command, not every one that starts with it")
  func wholeCommand() {
    let state = play(
      (0, permission(shown: false, command: "ls -la x")),
      (60, permission(shown: false, command: "ls")))
    let after = play((120, drawn(.command("ls"))), to: state)
    #expect(after.requests.map(\.reference.subject) == ["ls"])
    #expect(after.requests[0].isShown)
    #expect(!after.isFirstRequestUncertain)
    #expect(answersFromPalette(after))
  }

  @Test("After Codex settles one on a guess, a command quoted whole clears the doubt; in part not")
  func afterAGuess() {
    let both = play(
      (0, permission(shown: false, command: commandA)),
      (60, permission(shown: false, command: commandB)))
    // Codex's `PostToolUse` says a tool ended, not which one.
    let settled = play((120, .questionResolved), to: both)
    #expect(settled.requests.map(\.reference.subject) == [commandB])
    #expect(settled.isTrackLost)
    #expect(!answersFromPalette(settled))
    let cut = play((180, drawn(.commandStart("npm run test"))), to: settled)
    #expect(cut.isTrackLost)
    #expect(!answersFromPalette(cut))
    let whole = play((180, drawn(.command(commandB))), to: settled)
    #expect(whole.requests.map(\.isShown) == [true])
    #expect(!whole.isTrackLost)
    #expect(answersFromPalette(whole))
  }

  @Test("A file's name fits whole path components only")
  func fileComponents() {
    let sub = play((0, patch("App/SubModel.swift")), (60, drawn(.file("Model.swift"))))
    // Nothing fits: the dialog is some other request's, not this one's.
    #expect(!sub.isFirstRequestUncertain)
    let named = play((0, patch("App/B/Model.swift")), (60, drawn(.file("Model.swift"))))
    #expect(named.isFirstRequestUncertain)
  }
}

@Suite("Requests settled by what nothing else reports (#273, P2)")
struct SettledRequestsTests {
  private func request(_ command: String, agent: String? = nil) -> AgentSignal {
    .questionAsked(
      .approval, tool: "Bash",
      notice: AgentRequestNotice(
        content: .permission(
          AgentToolPermission(tool: .shell, toolName: "Bash", subject: command)),
        reference: AgentToolReference(tool: "Bash", agentID: agent, subject: command),
        isShown: true))
  }

  @Test("A batch resolved takes its agent's requests away — a refusal with a comment is one")
  func batchResolved() {
    let state = feed(request("rm a"), request("ls", agent: "a1"), .batchResolved(agentID: nil))
    #expect(state.requests.map(\.reference.agentID) == ["a1"])
    #expect(state.activity == .awaitingUser(.approval))
    // A sub-agent's dialog refused with Escape: its own batch is resolved.
    let sub = feed(.batchResolved(agentID: "a1"), to: state)
    #expect(sub.requests.isEmpty)
    #expect(sub.activity == .working)
  }

  @Test("A sub-agent's batch leaves the main agent's requests, announced ones too")
  func otherAgentsBatch() {
    let state = feed(network, request("rm a"), .batchResolved(agentID: "a1"))
    #expect(state.requests.count == 1)
    let main = feed(network, .batchResolved(agentID: nil))
    #expect(main.requests.isEmpty)
  }

  @Test("A turn failed on the account ends the turn and asks for the user")
  func turnFailed() {
    let prompt = AgentTerminalPrompt(kind: .account, message: "API Error: OAuth token has expired")
    let state = feed(.turnFailed(prompt))
    #expect(state.requests.map(\.content) == [.inTerminal(prompt)])
    // Said even behind a sub-agent's dialog still up.
    #expect(feed(request("ls", agent: "a1"), .turnFailed(prompt)).requests.count == 2)
    #expect(state.activity == .awaitingUser(.approval))
    #expect(feed(.promptSubmitted(byUser: true), to: state).requests.isEmpty)
  }

  @Test("Hooks silent past their delay: a startup dialog is most likely waiting, until they speak")
  func startup() {
    let started = AgentActivityState(
      activity: .idle, source: .unconfirmed(since: start))
    let late = AgentActivityMachine.reduce(
      started, .tick,
      context: AgentActivityContext(
        now: start.addingTimeInterval(11), isVisible: false,
        requestID: AgentRequestID(sessionID: session, key: "tick")))
    #expect(late.source == .inferred)
    guard case .inTerminal(let prompt) = late.requests.first?.content else {
      Issue.record("no startup request")
      return
    }
    #expect(prompt.kind == .startup)
    #expect(late.activity == .awaitingUser(.approval))
    // The dialog answered, the hooks speak: it is gone.
    #expect(feed(.channelConfirmed, to: late).requests.isEmpty)
    // Hooks that never speak — turned off, or failing: the terminal is all there is. What it
    // draws leaves the dialog waiting; a letter does not answer it, Return or Escape does.
    func reduce(_ event: AgentActivityInput, _ state: AgentActivityState) -> AgentActivityState {
      AgentActivityMachine.reduce(
        state, event,
        context: AgentActivityContext(
          now: start.addingTimeInterval(20), isVisible: false,
          requestID: AgentRequestID(sessionID: session, key: "key")))
    }
    let drawn = reduce(.output, late)
    #expect(drawn.activity == .awaitingUser(.approval))
    #expect(reduce(.userInput(Array("y".utf8)), drawn).requests.count == 1)
    for key in [[0x0D], [0x1B]] as [[UInt8]] {
      let answered = reduce(.userInput(key), drawn)
      #expect(answered.requests.isEmpty)
      #expect(answered.activity == .working)
    }
    // Without hooks, nothing is waited for.
    let bare = AgentActivityMachine.reduce(
      AgentActivityState(activity: .idle, source: .inferred), .tick,
      context: AgentActivityContext(
        now: start.addingTimeInterval(11), isVisible: false,
        requestID: AgentRequestID(sessionID: session, key: "tick")))
    #expect(bare.requests.isEmpty)
  }
}

@Suite("OSC 9 notifications in a terminal's output (#273)")
struct TerminalNotificationScannerTests {
  private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

  @Test("A notification ended by BEL, or by ESC \\, among other output")
  func found() {
    var scanner = TerminalNotificationScanner()
    let output = "a\u{1B}[1mb\u{1B}]9;Approval requested: ls\u{07}c\u{1B}]9;Question: Tea?\u{1B}\\d"
    #expect(scanner.scan(bytes(output)) == ["Approval requested: ls", "Question: Tea?"])
  }

  @Test("A notification split across reads, even inside its introducer")
  func split() {
    var scanner = TerminalNotificationScanner()
    #expect(scanner.scan(bytes("x\u{1B}]")).isEmpty)
    #expect(scanner.scan(bytes("9;Approval req")).isEmpty)
    #expect(scanner.scan(bytes("uested: ls\u{07}y")) == ["Approval requested: ls"])
    #expect(scanner.scan(bytes("z")).isEmpty)
  }

  @Test("Other OSC sequences, and one cut by another escape, say nothing")
  func ignored() {
    var scanner = TerminalNotificationScanner()
    #expect(scanner.scan(bytes("\u{1B}]0;title\u{07}\u{1B}]9;cut\u{1B}[0m")).isEmpty)
    #expect(scanner.scan(bytes("\u{1B}]9;next\u{07}")) == ["next"])
  }

  @Test("One that never ends is let go")
  func runaway() {
    var scanner = TerminalNotificationScanner()
    #expect(scanner.scan(bytes("\u{1B}]9;" + String(repeating: "a", count: 5000))).isEmpty)
    #expect(scanner.scan(bytes("\u{07}")).isEmpty)
  }
}

@Suite("A question asked without stopping the agent (#273, P3)")
struct AsynchronousQuestionTests {
  private let asked = AgentSignal.questionAsked(
    .question, tool: "request_user_input_async",
    notice: AgentRequestNotice(
      content: .questions([AgentQuestion(header: nil, text: "Which port?", options: [])]),
      reference: AgentToolReference(tool: "request_user_input_async", subject: "call_a"),
      isShown: false, key: "codex:call_a", isAsynchronous: true))

  private func play(_ steps: (TimeInterval, AgentSignal)...) -> AgentActivityState {
    var state = AgentActivityState(activity: .working, source: .structured)
    for (seconds, signal) in steps {
      state = AgentActivityMachine.reduce(
        state, .signal(signal), context: context("t\(seconds)", at: seconds))
    }
    return state
  }

  @Test("A permission asked meanwhile goes before it, and is answered as if it were alone")
  func permissionFirst() {
    let state = play((0, asked), (60, permission(shown: true)))
    #expect(state.requests.map(\.isAsynchronous) == [false, true])
    #expect(state.activity == .awaitingUser(.approval))
    #expect(!state.isFirstRequestUncertain)
  }

  @Test("Codex's word of it adds nothing; a form it announces still waits")
  func announcements() {
    let question = AgentSignal.dialogAnnounced(
      AgentTerminalPrompt(kind: .question, message: "Question: Which port?"))
    let form = AgentSignal.dialogAnnounced(
      AgentTerminalPrompt(kind: .form, message: "Approval requested by github"))
    #expect(play((0, asked), (60, question)).requests.count == 1)
    #expect(play((0, asked), (60, form)).requests.map(\.content.isAnnouncedOnly) == [true, false])
  }
}
