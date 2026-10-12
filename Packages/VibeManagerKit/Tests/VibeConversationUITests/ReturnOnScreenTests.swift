import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

@MainActor
@Suite("Return waits for the prompt to show the text, and is written again when not taken (#370)")
struct ReturnOnScreenTests {
  /// What Return does to the prompt of the agent.
  enum ReturnEffect {
    case send, lineBreak, lost
    /// Sent, the prompt still drawn with the text for that many readings.
    case sendAfter(reads: Int)
    /// Sent, a line break drawn for one reading before the prompt empties.
    case lineBreakThenSend
  }

  /// An agent whose prompt the screen shows: the text typed into it, which it may show late, and
  /// Return, which it may take for a line break or lose.
  private final class Agent: @unchecked Sendable {
    var written: [[UInt8]] = []
    var prompt = ""
    var lineBreak = false
    var effects: [ReturnEffect] = []
    /// Readings of the screen before the text typed shows in the prompt.
    var readsBeforeText = 0
    /// Whether the prompt showed the text when each Return was written.
    var textShownAtReturn: [Bool] = []
    var shown = ""
    var recognisable = true
    /// What the empty prompt shows: a hint.
    var hint = ""
    /// What the prompt shows in place of the text, when not the text itself.
    var placeholder: String?
    /// Readings left before a prompt sent is drawn empty, and whether a line break is drawn until.
    var clearsAfter: Int?
    var drawsLineBreakUntilClear = false
    var onReturn: (() -> Void)?

    func write(_ bytes: [UInt8]) {
      written.append(bytes)
      switch bytes {
      case [0x0D]:
        textShownAtReturn.append(!shown.isEmpty)
        onReturn?()
        switch effects.isEmpty ? .send : effects.removeFirst() {
        case .send: (prompt, lineBreak, shown) = ("", false, "")
        case .lineBreak: lineBreak = true
        case .lost: break
        case .sendAfter(let reads): clearsAfter = reads
        case .lineBreakThenSend: (clearsAfter, drawsLineBreakUntilClear) = (1, true)
        }
      case [0x7F]:
        if lineBreak { lineBreak = false } else if !prompt.isEmpty { prompt.removeLast() }
      default:
        prompt += String(decoding: bytes, as: UTF8.self)
      }
    }

    func screen() -> String? {
      guard recognisable else { return nil }
      if let reads = clearsAfter {
        if reads == 0 {
          (prompt, shown, clearsAfter, drawsLineBreakUntilClear) = ("", "", nil, false)
        } else {
          clearsAfter = reads - 1
        }
      } else if readsBeforeText > 0 {
        readsBeforeText -= 1
      } else {
        shown = prompt
      }
      let drawn = shown.isEmpty ? hint : placeholder ?? shown
      let lineBreak = lineBreak || drawsLineBreakUntilClear
      return "❯ earlier\n⏺ Done.\n────────\n❯ \(drawn)\(lineBreak ? "\n" : "")\n────────\n  ⏵⏵ auto"
    }
  }

  private func model(agent: Agent) -> ConversationModel {
    let model = ConversationModel(sessionID: SessionID())
    model.write = { agent.write($0) }
    model.readScreen = { agent.screen() }
    model.processRunning = { true }
    model.promptFormat = AgentPromptFormat(
      textEntry: .plain, submitDelay: .zero, shellEntry: ShellEntry(switchDelay: .zero),
      readsInputOnScreen: true)
    // Waited out only when the prompt keeps the text: lost, Return is written again at once.
    model.sendWaitLimit = .zero
    model.sendSettleDelay = .zero
    model.apply(ConversationSnapshot(entries: [], availability: .available))
    return model
  }

  @Test("Taken at once: one Return")
  func taken() async {
    let agent = Agent()
    let model = model(agent: agent)
    model.draft = "Bonjour ça va ?"
    #expect(await model.send())
    #expect(agent.written == [Array("Bonjour ça va ?".utf8), [0x0D]])
    #expect(agent.prompt.isEmpty)
  }

  @Test("The text slow to show: Return waits for it")
  func textShownLate() async {
    let agent = Agent()
    agent.readsBeforeText = 4
    let model = model(agent: agent)
    model.draft = "Bonjour ça va ?"
    #expect(await model.send())
    #expect(agent.textShownAtReturn == [true])
  }

  @Test("Return taken for a line break: the line break erased, Return written again")
  func lineBreak() async {
    let agent = Agent()
    agent.effects = [.lineBreak]
    let model = model(agent: agent)
    model.draft = "Bonjour ça va ?"
    #expect(await model.send())
    #expect(agent.written.suffix(3) == [[0x0D], [0x7F], [0x0D]])
    #expect(agent.prompt.isEmpty)
  }

  @Test("Return lost: written again, once")
  func lost() async {
    let agent = Agent()
    agent.effects = [.lost, .lost]
    let model = model(agent: agent)
    model.draft = "Bonjour ça va ?"
    #expect(await model.send())
    #expect(agent.written.filter { $0 == [0x0D] }.count == 2)
    #expect(!agent.written.contains([0x7F]))
  }

  @Test("A screen that cannot be read, or a command for the shell: one Return, as before")
  func notWatched() async {
    let unreadable = Agent()
    unreadable.recognisable = false
    unreadable.effects = [.lost]
    let first = model(agent: unreadable)
    first.draft = "hello"
    #expect(await first.send())
    #expect(unreadable.written.filter { $0 == [0x0D] }.count == 1)

    let shell = Agent()
    shell.effects = [.lost]
    let second = model(agent: shell)
    second.draft = "!git status"
    #expect(await second.send())
    #expect(shell.written.filter { $0 == [0x0D] }.count == 1)
  }

  @Test("An agent whose prompt is not read: one Return, as before")
  func formatWithoutScreen() async {
    let agent = Agent()
    agent.effects = [.lost]
    let model = model(agent: agent)
    model.promptFormat.readsInputOnScreen = false
    model.draft = "hello"
    #expect(await model.send())
    #expect(agent.written.filter { $0 == [0x0D] }.count == 1)
  }

  @Test("The prompt emptied a few readings after Return: one Return", .timeLimit(.minutes(1)))
  func sentLate() async {
    let agent = Agent()
    agent.effects = [.sendAfter(reads: 3)]
    let model = model(agent: agent)
    model.sendWaitLimit = .seconds(600)
    model.draft = "Bonjour ça va ?"
    #expect(await model.send())
    #expect(agent.written.filter { $0 == [0x0D] }.count == 1)
  }

  @Test("A line break drawn once, the prompt then emptied: nothing erased", .timeLimit(.minutes(1)))
  func lineBreakRedrawn() async {
    let agent = Agent()
    agent.effects = [.lineBreakThenSend]
    let model = model(agent: agent)
    model.sendWaitLimit = .seconds(600)
    model.draft = "Bonjour ça va ?"
    #expect(await model.send())
    #expect(!agent.written.contains([0x7F]))
    #expect(agent.written.filter { $0 == [0x0D] }.count == 1)
  }

  @Test("A short text sent, the empty prompt showing a hint with the same word: one Return")
  func hintIsNotTheText() async {
    let agent = Agent()
    agent.hint = "Try \"fix lint errors\""
    let model = model(agent: agent)
    model.draft = "fix"
    #expect(await model.send())
    #expect(agent.written.filter { $0 == [0x0D] }.count == 1)
  }

  @Test("A long text shown as a placeholder, its Return lost: written again")
  func pastedTextLost() async {
    let agent = Agent()
    agent.placeholder = "[Pasted text #1 +40 lines]"
    agent.effects = [.lost]
    let model = model(agent: agent)
    model.draft = "hello"
    #expect(await model.send())
    #expect(agent.written.filter { $0 == [0x0D] }.count == 2)
  }

  @Test("A request reported after Return: nothing more typed into its dialog")
  func requestAfterReturn() async {
    let agent = Agent()
    agent.effects = [.lost]
    let model = model(agent: agent)
    agent.onReturn = { [weak model] in
      MainActor.assumeIsolated { model?.activity = .awaitingUser(.approval) }
    }
    model.draft = "hello"
    #expect(await model.send())
    #expect(agent.written.filter { $0 == [0x0D] }.count == 1)
  }
}
