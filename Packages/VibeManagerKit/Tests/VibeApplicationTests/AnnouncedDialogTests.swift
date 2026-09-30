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

  @Test("The main agent's turn or prompt takes the announced dialog away", arguments: [
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

  @Test("Codex's form for an MCP tool arms the permission it reported, adding nothing")
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
    #expect(state.requests[0].isShown)
    #expect(!state.isFirstRequestUncertain)
    // A server's own form, no permission of it waiting: a request answered in the terminal.
    let own = feed(form)
    #expect(own.requests.first?.content.isAnnouncedOnly == true)
  }

  @Test("A dialog arms only the request it names: an older one settled with no dialog is dropped")
  func stale() {
    // `ls` was settled by Codex's automatic review, with no dialog and no report of it.
    let stale = feed(permission(shown: false, command: "ls"))
    let drawnB = AgentSignal.dialogDrawn(AgentDrawnDialog(.commandStart("rm x")))
    // B's dialog read before B's report: `ls` is not armed in its place.
    let early = feed(drawnB, to: stale)
    #expect(!early.requests[0].isShown)
    let reported = AgentActivityMachine.reduce(
      early, .signal(permission(shown: false, command: "rm x")), context: context("b", at: 1))
    #expect(reported.requests.map(\.reference.subject) == ["rm x"])
    #expect(reported.requests[0].isShown)
    #expect(!reported.isFirstRequestUncertain)
    // B's report read first: B is armed, `ls` goes.
    let later = feed(permission(shown: false, command: "rm x"), drawnB, to: stale)
    #expect(later.requests.map(\.reference.subject) == ["rm x"])
    #expect(later.requests[0].isShown)
  }

  @Test("A dialog said drawn long before a report arms nothing")
  func drawnLongBefore() {
    let drawn = feed(.dialogDrawn(AgentDrawnDialog(.commandStart("ls"))))
    let reported = AgentActivityMachine.reduce(
      drawn, .signal(permission(shown: false)), context: context("late", at: 60))
    #expect(!reported.requests[0].isShown)
  }

  @Test("Codex's word that its dialog is drawn arms the permission it reported")
  func drawn() {
    let reported = feed(permission(shown: false))
    #expect(!reported.requests[0].isShown)
    let drawn = feed(.dialogDrawn(AgentDrawnDialog(.commandStart("l"))), to: reported)
    #expect(drawn.requests[0].isShown)
    // Another command's dialog does not arm it.
    #expect(!feed(.dialogDrawn(AgentDrawnDialog(.commandStart("rm"))), to: reported).requests[0].isShown)
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

@Suite("A dialog whose quote fits several requests arms none (#280)")
struct AmbiguousDrawnDialogTests {
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

  @Test("Two commands with the quoted start: neither is armed nor taken away, nothing answered")
  func commandStart() {
    let state = play(
      (0, permission(shown: false, command: commandA)),
      (60, permission(shown: false, command: commandB)),
      (120, drawn(.commandStart("npm run test"))))
    #expect(state.requests.map(\.reference.subject) == [commandA, commandB])
    #expect(state.requests.allSatisfy { !$0.isShown })
    #expect(state.isFirstRequestUncertain)
    // The first card says to answer in the session, the second waits behind it.
    let keymap = PaletteKeymap()
    #expect(state.answering(state.requests[0], keymap: keymap) == .inTerminalOnly(.uncertain))
    #expect(state.answering(state.requests[1], keymap: keymap) == .inTerminalOnly(.queued))
    #expect(!answersFromPalette(state))
  }

  @Test("Codex's end of a tool settles one; the next dialog names the other alone and arms it")
  func namedOnceAlone() {
    let ambiguous = play(
      (0, permission(shown: false, command: commandA)),
      (60, permission(shown: false, command: commandB)),
      (120, drawn(.commandStart("npm run test"))))
    // Codex's `PostToolUse` says a tool ended, not which one.
    let settled = play((180, .questionResolved), to: ambiguous)
    #expect(settled.requests.map(\.reference.subject) == [commandB])
    #expect(!answersFromPalette(settled))
    let armed = play((240, drawn(.commandStart("npm run test"))), to: settled)
    #expect(armed.requests.map(\.isShown) == [true])
    #expect(!armed.isFirstRequestUncertain)
    #expect(answersFromPalette(armed))
  }

  @Test("A dialog read before its report, an older look-alike waiting: the report brings doubt")
  func reportAfterItsDialog() {
    // A was settled by Codex's automatic review, with no dialog; it waits for its tool to end.
    let older = play((0, permission(shown: false, command: commandA)))
    // B's dialog is drawn, its word read before B's report: only A fits it yet, and is armed.
    let early = play((60, drawn(.commandStart("npm run test"))), to: older)
    #expect(early.requests.map(\.isShown) == [true])
    // B's report, two seconds on: the dialog may be B's. Neither card answers.
    let reported = play((62, permission(shown: false, command: commandB)), to: early)
    #expect(reported.requests.map(\.reference.subject) == [commandA, commandB])
    #expect(reported.requests.allSatisfy { !$0.isShown })
    #expect(reported.isFirstRequestUncertain)
    #expect(!answersFromPalette(reported))
    // A report long after is not this dialog's: A stays armed.
    let late = play((600, permission(shown: false, command: commandB)), to: early)
    #expect(late.requests.map(\.isShown) == [true, false])
    #expect(answersFromPalette(late))
  }

  @Test("A dialog read before any report arms the first that fits it, until a second fits it too")
  func secondReportAfterItsDialog() {
    let armed = play(
      (0, drawn(.commandStart("npm run test"))), (0.5, permission(shown: false, command: commandA)))
    #expect(armed.requests.map(\.isShown) == [true])
    #expect(answersFromPalette(armed))
    let both = play((2, permission(shown: false, command: commandB)), to: armed)
    #expect(both.requests.allSatisfy { !$0.isShown })
    #expect(!answersFromPalette(both))
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
  }

  @Test("Two patches of a file with the quoted name: neither is armed nor taken away")
  func file() {
    let state = play((0, patch("App/A/Model.swift")), (60, patch("App/B/Model.swift")))
    let after = play((120, drawn(.file("Model.swift"))), to: state)
    #expect(after.requests.count == 2)
    #expect(after.requests.allSatisfy { !$0.isShown })
    #expect(!answersFromPalette(after))
  }

  @Test("A file's name fits whole path components only")
  func fileComponents() {
    let state = play((0, patch("App/SubModel.swift")), (60, patch("App/B/Model.swift")))
    let after = play((120, drawn(.file("Model.swift"))), to: state)
    #expect(after.requests.map(\.reference.subject) == ["App/B/Model.swift"])
    #expect(after.requests[0].isShown)
    #expect(!after.isFirstRequestUncertain)
  }

  @Test("Several files quoted, two patches waiting: neither is armed; one alone is")
  func files() {
    let state = play((0, patch("a.swift\nb.swift")), (60, patch("c.swift\nd.swift")))
    let after = play((120, drawn(.files)), to: state)
    #expect(after.requests.count == 2)
    #expect(after.requests.allSatisfy { !$0.isShown })
    #expect(!answersFromPalette(after))
    let alone = play((0, patch("a.swift\nb.swift")), (120, drawn(.files)))
    #expect(alone.requests.map(\.isShown) == [true])
    #expect(answersFromPalette(alone))
  }

  @Test("Two tools of the MCP server a form names: neither is armed")
  func server() {
    let state = play((0, mcp("create_issue")), (60, mcp("delete_repo")))
    let after = play((120, drawn(.server("github"))), to: state)
    #expect(after.requests.allSatisfy { !$0.isShown })
    #expect(!answersFromPalette(after))
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
