import Foundation
import Testing
import VibeApplication

@testable import VibeUI

@MainActor
@Suite("A coordinator's message is sent, not left in the child's prompt (#435)")
struct CoordinationReturnTests {
  /// Claude Code's prompt as its screen shows it: the text typed shows after a few readings, and
  /// the Returns listed as lost leave it there.
  private final class Agent: @unchecked Sendable {
    var prompt = ""
    var readsBeforeText = 0
    var lostReturns = 0
    var written: [[UInt8]] = []

    func write(_ bytes: [UInt8]) -> Bool {
      written.append(bytes)
      if bytes == [0x0D] {
        if lostReturns > 0 { lostReturns -= 1 } else { prompt = "" }
      }
      return true
    }

    func screen() -> String? {
      if readsBeforeText > 0 { readsBeforeText -= 1 }
      let shown = readsBeforeText > 0 ? "" : prompt
      return "⏺ Done.\n✻ Worked for 6s\n────────\n❯ \(shown)\n────────\n  ⏵⏵ auto"
    }
  }

  private let text = "[From coordinator “Ajout de tickets”] Le ticket #411 est prêt à reprendre."

  private func submit(_ agent: Agent) async -> TypingOutcome {
    var promptReturn = PromptReturn()
    promptReturn.sendWaitLimit = .milliseconds(200)
    promptReturn.sendSettleDelay = .zero
    let format = AgentPromptFormat(readsInputOnScreen: true)
    return await SessionLauncher.submit(
      text, keys: [0x0D], format: format, promptReturn: promptReturn,
      readScreen: { agent.screen() }, write: { agent.write($0) }, state: { .atRest })
  }

  @Test("Return lost by the agent is written again, and the message sent")
  func lostReturnIsWrittenAgain() async {
    let agent = Agent()
    agent.prompt = text
    agent.lostReturns = 1
    #expect(await submit(agent) == .submitted)
    #expect(agent.prompt.isEmpty)
    #expect(agent.written.filter { $0 == [0x0D] }.count == 2)
  }

  @Test("Return waits for the prompt to show the message")
  func returnWaitsForTheText() async {
    let agent = Agent()
    agent.prompt = text
    agent.readsBeforeText = 3
    #expect(await submit(agent) == .submitted)
    #expect(agent.readsBeforeText == 0)
    #expect(agent.prompt.isEmpty)
  }

  @Test("A message the agent never takes is said to be left in its prompt, not sent")
  func neverTakenIsLeftInInput() async {
    let agent = Agent()
    agent.prompt = text
    agent.lostReturns = 5
    #expect(await submit(agent) == .leftInInput)
  }
}
