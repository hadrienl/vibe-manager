import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private let session = SessionID()
private let start = Date(timeIntervalSince1970: 3_000_000)

private func context(
  _ key: String = "l1", at seconds: TimeInterval = 0, visible: Bool = false
) -> AgentActivityContext {
  AgentActivityContext(
    now: start.addingTimeInterval(seconds), isVisible: visible, approvalAnswerKeys: [[0x31]],
    requestID: AgentRequestID(sessionID: session, key: key))
}

private func permission(
  _ command: String, agent: String? = nil, shown: Bool = true
) -> AgentSignal {
  .questionAsked(
    .approval, tool: "Bash",
    notice: AgentRequestNotice(
      content: .permission(
        AgentToolPermission(tool: .shell, toolName: "Bash", subject: command)),
      reference: AgentToolReference(tool: "Bash", agentID: agent, subject: command),
      isShown: shown))
}

private func question(shown: Bool) -> AgentSignal {
  .questionAsked(
    .question, tool: "AskUserQuestion",
    notice: AgentRequestNotice(
      content: .questions([AgentQuestion(header: nil, text: "Tea?", options: [.init(label: "Yes")])]
      ),
      reference: AgentToolReference(tool: "AskUserQuestion"), isShown: shown))
}

/// Feeds signals one after the other, each carried by its own log line, five seconds apart.
private func feed(_ signals: AgentSignal..., to state: AgentActivityState = working())
  -> AgentActivityState
{
  var state = state
  let offset = TimeInterval(state.requests.count * 100)
  for (index, signal) in signals.enumerated() {
    state = AgentActivityMachine.reduce(
      state, .signal(signal),
      context: context("l\(Int(offset) + index)", at: offset + TimeInterval(index) * 5))
  }
  return state
}

private func working() -> AgentActivityState {
  AgentActivityState(activity: .working, source: .structured)
}

/// Answers every request from outside, as Claude Code's keymap would.
private struct AnyKeymap: AgentAnswerKeymap {
  func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind> {
    [.allowOnce, .deny, .chooseOption]
  }

  func keystrokes(for answer: AgentAnswer, to content: AgentRequestContent) -> [[UInt8]]? {
    [[0x31]]
  }
}

@Suite("Agent requests: the queue of #40")
struct AgentRequestQueueTests {
  @Test("A request is queued with what it asks, and the agent waits on the first")
  func queued() {
    let state = feed(permission("touch a", agent: "A"), permission("touch b", agent: "B"))
    #expect(state.activity == .awaitingUser(.approval))
    #expect(state.requests.map(\.reference.subject) == ["touch a", "touch b"])
    #expect(state.requests.map(\.id.key) == ["l0", "l1"])
    #expect(!state.isFirstRequestUncertain)
  }

  @Test("Only the first request, once drawn and certain, is answered from outside")
  func onlyTheFirst() {
    let state = feed(permission("touch a", agent: "A"), permission("touch b", agent: "B"))
    #expect(state.answering(state.requests[0], keymap: AnyKeymap()).answers.contains(.allowOnce))
    #expect(state.answering(state.requests[1], keymap: AnyKeymap()) == .inTerminalOnly(.queued))
    #expect(state.answering(state.requests[0], keymap: nil) == .inTerminalOnly(.notSupported))
  }

  @Test("A question announced before its dialog is drawn waits, and the dialog arms it")
  func announcedThenShown() {
    let announced = feed(question(shown: false))
    #expect(announced.requests.count == 1)
    #expect(
      announced.answering(announced.requests[0], keymap: AnyKeymap())
        == .inTerminalOnly(.notYetShown))
    let shown = feed(question(shown: true), to: announced)
    #expect(shown.requests.count == 1)
    #expect(shown.requests[0].isShown)
    #expect(shown.requests[0].id == announced.requests[0].id)
  }

  @Test("The tool that settles the first request takes it away, and the next is on screen")
  func settledInOrder() {
    let asked = feed(permission("touch a", agent: "A"), permission("touch b", agent: "B"))
    let other = feed(.toolFinished("Read", agentID: "A", subject: "/a"), to: asked)
    #expect(other.requests.count == 2)
    let first = feed(.toolFinished("Bash", agentID: "A", subject: "touch a"), to: asked)
    #expect(first.requests.map(\.reference.subject) == ["touch b"])
    #expect(first.activity == .awaitingUser(.approval))
    #expect(!first.isFirstRequestUncertain)
    let both = feed(.toolFinished("Bash", agentID: "B", subject: "touch b"), to: first)
    #expect(both.requests.isEmpty)
    #expect(both.activity == .working)
  }

  @Test("A settlement out of turn, or one that cannot be told apart, leaves the first uncertain")
  func uncertain() {
    let asked = feed(
      permission("touch a", agent: "A"), permission("touch b", agent: "B"),
      permission("touch c", agent: "C"))
    let outOfTurn = feed(.toolFinished("Bash", agentID: "B", subject: "touch b"), to: asked)
    #expect(outOfTurn.requests.map(\.reference.subject) == ["touch a", "touch c"])
    #expect(outOfTurn.isFirstRequestUncertain)
    #expect(
      outOfTurn.answering(outOfTurn.requests[0], keymap: AnyKeymap())
        == .inTerminalOnly(.uncertain))

    let likely = feed(.toolFinished("Bash", agentID: "A"), to: asked)
    #expect(likely.requests.map(\.reference.subject) == ["touch b", "touch c"])
    #expect(likely.isFirstRequestUncertain)

    let unnamed = feed(.questionResolved, to: asked)
    #expect(unnamed.requests.map(\.reference.subject) == ["touch b", "touch c"])
    #expect(unnamed.isFirstRequestUncertain)

    // Alone, the one left is the dialog on screen: it is certain again.
    let alone = feed(.toolFinished("Bash", agentID: "B", subject: "touch b"), to: likely)
    #expect(alone.requests.map(\.reference.subject) == ["touch c"])
    #expect(!alone.isFirstRequestUncertain)
  }

  @Test("Requests of one session arriving in the same second are answered in the terminal")
  func sameSecond() {
    var state = working()
    for (index, command) in ["touch a", "touch b"].enumerated() {
      state = AgentActivityMachine.reduce(
        state, .signal(permission(command, agent: command)),
        context: context("s\(index)", at: 0.4))
    }
    #expect(state.isFirstRequestUncertain)
    #expect(state.answering(state.requests[0], keymap: AnyKeymap()) == .inTerminalOnly(.uncertain))
    // One settled in the terminal: the other is alone, and answered from the palette again.
    let settled = AgentActivityMachine.reduce(
      state, .signal(.toolFinished("Bash", agentID: "touch b", subject: "touch b")),
      context: context())
    #expect(!settled.isFirstRequestUncertain)
    #expect(
      settled.answering(settled.requests[0], keymap: AnyKeymap()).answers.contains(.allowOnce))
  }

  @Test("A sub-agent's dialog outlives the main turn and a background task's prompt")
  func outlivesTheTurn() {
    let state = feed(
      permission("touch a", agent: "A"), .turnEnded, .promptSubmitted(byUser: false))
    #expect(state.activity == .awaitingUser(.approval))
    #expect(state.requests.count == 1)
  }

  @Test("An interruption, the end of the agent or of its process drops every request")
  func dropped() {
    let asked = feed(permission("touch a", agent: "A"), permission("touch b", agent: "B"))
    #expect(feed(.interrupted, to: asked).requests.isEmpty)
    #expect(feed(.agentEnded, to: asked).requests.isEmpty)
    let ended = AgentActivityMachine.reduce(asked, .processEnded, context: context())
    #expect(ended.requests.isEmpty)
  }

  @Test("An answer sent to the first request takes it away; one sent to another does nothing")
  func answerSent() {
    let asked = feed(permission("touch a", agent: "A"), permission("touch b", agent: "B"))
    let wrong = AgentActivityMachine.reduce(
      asked, .answerSent(asked.requests[1].id), context: context(at: 50))
    #expect(wrong.requests.count == 2)
    let right = AgentActivityMachine.reduce(
      asked, .answerSent(asked.requests[0].id), context: context())
    #expect(right.requests.map(\.reference.subject) == ["touch b"])
  }

  @Test("A key typed in the terminal answers the dialog on screen: the first request")
  func keyTyped() {
    let asked = feed(permission("touch a", agent: "A"), permission("touch b", agent: "B"))
    let typed = AgentActivityMachine.reduce(asked, .userInput([0x31]), context: context())
    #expect(typed.requests.map(\.reference.subject) == ["touch b"])
    #expect(typed.activity == .awaitingUser(.approval))
  }

  @Test("The same report read twice is one request")
  func replayed() {
    let once = AgentActivityMachine.reduce(
      working(), .signal(permission("touch a")), context: context("same"))
    let twice = AgentActivityMachine.reduce(
      once, .signal(permission("touch a")), context: context("same"))
    #expect(twice.requests.count == 1)
  }

  @Test("A permission cut short can be refused, never allowed")
  func truncated() {
    let state = feed(
      .questionAsked(
        .approval, tool: "Write",
        notice: AgentRequestNotice(
          content: .permission(
            AgentToolPermission(
              tool: .write, toolName: "Write", subject: "/a", isComplete: false)),
          reference: AgentToolReference(tool: "Write", subject: "/a"), isShown: true)))
    let answers = state.answering(state.requests[0], keymap: AnyKeymap()).answers
    #expect(answers.contains(.deny))
    #expect(answers.isDisjoint(with: [.allowOnce, .allowAlways]))
  }

  @Test("A question without a readable report is still queued, to be answered in the terminal")
  func withoutNotice() {
    let state = feed(.questionAsked(.approval, tool: "Bash"))
    #expect(state.requests.count == 1)
    #expect(state.requests[0].content == .unreadable(tool: "Bash"))
    #expect(!state.requests[0].isShown)
  }

  @Test("Requests change what the session shows, so the palette hears of them")
  func shown() {
    let asked = feed(permission("touch a"))
    let again = AgentActivityMachine.reduce(
      asked, .signal(permission("touch b")), context: context("other"))
    #expect(!again.showsTheSame(as: asked))
  }
}
