import Foundation
import Testing

@testable import VibeApplication

private let start = Date(timeIntervalSince1970: 1_000_000)

private func at(_ seconds: TimeInterval) -> Date {
  start.addingTimeInterval(seconds)
}

private func context(
  _ seconds: TimeInterval = 0, visible: Bool = false, keys: Set<[UInt8]> = [[0x0D], [0x31]]
) -> AgentActivityContext {
  AgentActivityContext(now: at(seconds), isVisible: visible, approvalAnswerKeys: keys)
}

/// A state as it is once the hooks have spoken.
private func structured(_ activity: AgentActivity = .idle, unread: Date? = nil)
  -> AgentActivityState
{
  AgentActivityState(activity: activity, unreadSince: unread, source: .structured)
}

private func reduce(
  _ state: AgentActivityState, _ inputs: AgentActivityInput...,
  context: AgentActivityContext =
    context()
) -> AgentActivityState {
  inputs.reduce(state) { AgentActivityMachine.reduce($0, $1, context: context) }
}

@Suite("Agent activity: structured signals")
struct AgentActivityStructuredTests {
  @Test("A prompt makes the agent work, and its end leaves it waiting")
  func promptThenTurnEnd() {
    let working = reduce(structured(), .signal(.promptSubmitted(byUser: true)))
    #expect(working.activity == .working)
    let done = reduce(working, .signal(.turnEnded), context: context(5, visible: true))
    #expect(done.activity == .idle)
    #expect(done.unreadSince == nil)
  }

  @Test("An answer finished out of sight is unread, dated when it finished")
  func turnEndedUnseenIsUnread() {
    let done = reduce(
      structured(.working), .signal(.turnEnded), context: context(7, visible: false))
    #expect(done.activity == .idle)
    #expect(done.unreadSince == at(7))
  }

  @Test("A second unread answer keeps the date of the first")
  func unreadKeepsFirstDate() {
    let done = reduce(
      structured(.working, unread: at(1)), .signal(.turnEnded), context: context(9))
    #expect(done.unreadSince == at(1))
  }

  @Test("Writing to the agent reads what it said, a background task resuming it does not")
  func promptClearsUnreadOnlyFromUser() {
    let unread = structured(unread: at(1))
    #expect(reduce(unread, .signal(.promptSubmitted(byUser: true))).unreadSince == nil)
    let resumed = reduce(unread, .signal(.promptSubmitted(byUser: false)))
    #expect(resumed.activity == .working)
    #expect(resumed.unreadSince == at(1))
  }

  @Test("A question holds even while the session is in front of the user")
  func questionHoldsWhileVisible() {
    for kind in [AgentQuestionKind.approval, .question] {
      let asked = reduce(
        structured(.working), .signal(.questionAsked(kind)), context: context(visible: true))
      #expect(asked.activity == .awaitingUser(kind))
      let still = reduce(asked, .output, .tick, context: context(60, visible: true))
      #expect(still.activity == .awaitingUser(kind))
    }
  }

  @Test("A resolved question puts the agent back to work")
  func questionResolved() {
    let resolved = reduce(structured(.awaitingUser(.approval)), .signal(.questionResolved))
    #expect(resolved.activity == .working)
  }

  @Test("A permission key answers a permission, an arrow key does not")
  func approvalKeys() {
    let asked = structured(.awaitingUser(.approval))
    #expect(reduce(asked, .userInput([0x31])).activity == .working)
    #expect(reduce(asked, .userInput([0x0D])).activity == .working)
    #expect(reduce(asked, .userInput([0x1B, 0x5B, 0x42])).activity == .awaitingUser(.approval))
    #expect(reduce(asked, .userInput([0x32])).activity == .awaitingUser(.approval))
  }

  @Test("No key answers a question: a free answer is typed one letter at a time")
  func questionIgnoresKeys() {
    let asked = structured(.awaitingUser(.question))
    #expect(reduce(asked, .userInput([0x0D])).activity == .awaitingUser(.question))
    #expect(reduce(asked, .userInput([0x31])).activity == .awaitingUser(.question))
  }

  @Test("A permission asked again after a provisional answer is a question again")
  func questionComesBack() {
    let answered = reduce(structured(.awaitingUser(.approval)), .userInput([0x0D]))
    #expect(answered.activity == .working)
    let again = reduce(answered, .signal(.questionAsked(.approval)))
    #expect(again.activity == .awaitingUser(.approval))
  }

  @Test("Escape or Control-C stops a turn, and nothing is left to read")
  func interruptKeys() {
    for key: [UInt8] in [[0x1B], [0x03]] {
      let stopped = reduce(structured(.working), .userInput(key))
      #expect(stopped.activity == .idle)
      #expect(stopped.unreadSince == nil)
    }
    // An arrow key begins with Escape but is not one.
    #expect(reduce(structured(.working), .userInput([0x1B, 0x5B, 0x41])).activity == .working)
  }

  @Test("An interruption the agent reports leaves it idle with nothing unread")
  func interruptedSignal() {
    let stopped = reduce(structured(.working), .signal(.interrupted))
    #expect(stopped.activity == .idle)
    #expect(stopped.unreadSince == nil)
  }

  @Test("The idle reminder only ends a turn nobody reported ending")
  func waitingForInput() {
    #expect(reduce(structured(.working), .signal(.waitingForInput)).activity == .idle)
    #expect(
      reduce(structured(.awaitingUser(.question)), .signal(.waitingForInput)).activity
        == .awaitingUser(.question))
  }

  @Test("Output never moves an agent whose hooks report it")
  func outputIgnoredWhenStructured() {
    #expect(reduce(structured(), .output).activity == .idle)
  }

  @Test("A process that ends keeps what was unread, and its question with it goes")
  func processEnded() {
    let ended = reduce(structured(.awaitingUser(.approval), unread: at(1)), .processEnded)
    #expect(ended.activity == .idle)
    #expect(ended.unreadSince == at(1))
  }

  @Test("A new process starts idle, unconfirmed, and still owes the unread answer")
  func processStarted() {
    let started = reduce(
      structured(.working, unread: at(1)), .processStarted(structured: true), context: context(3))
    #expect(started.activity == .idle)
    #expect(started.source == .unconfirmed(since: at(3)))
    #expect(started.unreadSince == at(1))
  }
}

@Suite("Agent activity: without structured signals")
struct AgentActivityInferredTests {
  private let inferred = AgentActivityState(source: .inferred)

  @Test("Output makes the agent work, and three silent seconds make it wait")
  func outputThenSilence() {
    let working = reduce(inferred, .output, context: context(0))
    #expect(working.activity == .working)
    #expect(reduce(working, .tick, context: context(2)).activity == .working)
    #expect(reduce(working, .tick, context: context(3)).activity == .idle)
  }

  @Test("The echo of a keystroke is not work")
  func echoIgnored() {
    let typed = reduce(inferred, .userInput([0x61]), context: context(0))
    #expect(reduce(typed, .output, context: context(0.1)).activity == .idle)
    #expect(reduce(typed, .output, context: context(0.5)).activity == .working)
  }

  @Test("Never a question, never an unread answer")
  func neverNeedsAttention() {
    var state = inferred
    for input: AgentActivityInput in [.output, .userInput([0x0D]), .userInput([0x31]), .tick] {
      state = reduce(state, input, context: context(10))
      #expect(state.unreadSince == nil)
      if case .awaitingUser = state.activity { Issue.record("inferred a question") }
    }
  }

  @Test("Hooks that never speak leave the session to its output after ten seconds")
  func unconfirmedFallsBack() {
    let launched = reduce(inferred, .processStarted(structured: true), context: context(0))
    #expect(reduce(launched, .tick, context: context(9)).source == .unconfirmed(since: at(0)))
    #expect(reduce(launched, .tick, context: context(10)).source == .inferred)
    // Until then, its output already counts.
    #expect(reduce(launched, .output, context: context(1)).activity == .working)
  }

  @Test("Hooks that speak late still take over")
  func lateSignalConfirms() {
    let late = reduce(inferred, .signal(.promptSubmitted(byUser: true)))
    #expect(late.source == .structured)
    #expect(late.activity == .working)
  }

  @Test("Deadlines: the confirmation, then the silence")
  func deadlines() {
    let launched = reduce(inferred, .processStarted(structured: true), context: context(0))
    #expect(AgentActivityMachine.nextDeadline(of: launched) == at(10))
    let working = reduce(inferred, .output, context: context(4))
    #expect(AgentActivityMachine.nextDeadline(of: working) == at(7))
    #expect(AgentActivityMachine.nextDeadline(of: structured(.working)) == nil)
  }
}

@Test("Activities are written as the words the ticket uses")
func activityCoding() throws {
  let all: [AgentActivity] = [.idle, .working, .awaitingUser(.approval), .awaitingUser(.question)]
  let data = try JSONEncoder().encode(all)
  #expect(
    String(decoding: data, as: UTF8.self)
      == #"["idle","working","awaitingUser.approval","awaitingUser.question"]"#)
  #expect(try JSONDecoder().decode([AgentActivity].self, from: data) == all)
}
