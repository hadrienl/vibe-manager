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
