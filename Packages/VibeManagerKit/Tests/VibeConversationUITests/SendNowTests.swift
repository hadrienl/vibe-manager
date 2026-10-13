import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

@MainActor
@Suite("Send Now under a message queued during a turn (#341)")
struct SendNowTests {
  nonisolated static let queuedScreen = """
    ✻ Running… (esc to interrupt)
    ────
    ❯
    ────
      Press up to edit queued messages · ctrl+x ctrl+s to send now
    """
  nonisolated static let sendNowKey: [UInt8] = [0x18, 0x13]

  private final class Terminal: @unchecked Sendable {
    var screen: String? = SendNowTests.queuedScreen
    var written: [[UInt8]] = []
    var shown = 0
  }

  private func model(
    terminal: Terminal, sendNowKey: [UInt8]? = SendNowTests.sendNowKey, working: Bool = true
  ) -> ConversationModel {
    let model = ConversationModel(sessionID: SessionID())
    model.write = { terminal.written.append($0) }
    model.readScreen = { terminal.screen }
    model.showTerminal = { terminal.shown += 1 }
    model.processRunning = { true }
    model.promptFormat = AgentPromptFormat(
      textEntry: .plain, sendNowKey: sendNowKey, submitDelay: .zero,
      shellEntry: ShellEntry(switchDelay: .zero, queuesWhileWorking: true))
    model.apply(ConversationSnapshot(entries: [], availability: .available))
    if working { model.activity = .working }
    return model
  }

  private func send(_ text: String, to model: ConversationModel) async {
    model.draft = text
    #expect(await model.send())
  }

  @Test("A message sent during a turn can be sent now, from the last one queued only")
  func queuedMessage() async {
    let terminal = Terminal()
    let model = model(terminal: terminal)
    await send("first", to: model)
    #expect(model.echoes.count == 1)
    #expect(model.canSendNow(model.echoes[0]))
    await send("second", to: model)
    #expect(!model.canSendNow(model.echoes[0]))
    #expect(model.canSendNow(model.echoes[1]))
  }

  @Test("Not for a message sent at rest, a command, an agent without the key, or a request")
  func notQueued() async {
    let atRest = model(terminal: Terminal(), working: false)
    await send("hello", to: atRest)
    atRest.activity = .working
    #expect(!atRest.canSendNow(atRest.echoes[0]))

    let shell = model(terminal: Terminal())
    await send("!git status", to: shell)
    #expect(shell.echoes.first?.kind.isShell == true)
    #expect(shell.sendNowEchoID == nil)

    let codex = model(terminal: Terminal(), sendNowKey: nil)
    await send("hello", to: codex)
    #expect(!codex.canSendNow(codex.echoes[0]))

    let asking = model(terminal: Terminal())
    await send("hello", to: asking)
    asking.activity = .awaitingUser(.approval)
    #expect(!asking.canSendNow(asking.echoes[0]))
  }

  @Test("The turn ended: nothing left to send now")
  func turnEnded() async {
    let model = model(terminal: Terminal())
    await send("hello", to: model)
    model.activity = .idle
    #expect(model.sendNowEchoID == nil)
  }

  @Test("A message left over from an earlier turn — put back in the prompt by Escape — has none")
  func leftOverFromEarlierTurn() async {
    let model = model(terminal: Terminal())
    await send("hello", to: model)
    model.activity = .idle
    model.activity = .working
    #expect(model.echoes.count == 1)
    #expect(model.sendNowEchoID == nil)
  }

  @Test("A request answered goes back to the same turn: the message can still be sent now")
  func requestAnswered() async {
    let model = model(terminal: Terminal())
    await send("hello", to: model)
    model.activity = .awaitingUser(.approval)
    #expect(model.sendNowEchoID == nil)
    model.activity = .working
    #expect(model.sendNowEchoID == model.echoes.first?.id)
  }

  @Test("Clicked twice while the screen is read: the key is written once, the button goes")
  func clickedTwice() async {
    let terminal = Terminal()
    let model = model(terminal: terminal)
    await send("hello", to: model)
    terminal.written = []
    model.readScreen = {
      await Task.yield()
      return Self.queuedScreen
    }
    async let first: Void = model.sendNow()
    async let second: Void = model.sendNow()
    _ = await (first, second)
    #expect(terminal.written == [Self.sendNowKey])
    #expect(model.sendNowEchoID == nil)
    // Queued after it, a message can be sent now in turn.
    await send("again", to: model)
    #expect(model.sendNowEchoID == model.echoes.last?.id)
  }

  @Test("The hint on screen: the agent's key is written")
  func writesKey() async {
    let terminal = Terminal()
    let model = model(terminal: terminal)
    await send("hello", to: model)
    terminal.written = []
    await model.sendNow()
    #expect(terminal.written == [Self.sendNowKey])
    #expect(terminal.shown == 0)
  }

  @Test("No hint on screen, or none to read: nothing written, the terminal shown")
  func noHint() async {
    for screen in ["────\n❯ \n────\n  ? for shortcuts", nil] {
      let terminal = Terminal()
      let model = model(terminal: terminal)
      await send("hello", to: model)
      terminal.written = []
      terminal.screen = screen
      await model.sendNow()
      #expect(terminal.written.isEmpty)
      #expect(terminal.shown == 1)
    }
  }

  @Test("A request reported while the screen is read: nothing written")
  func requestWhileReading() async {
    let terminal = Terminal()
    let model = model(terminal: terminal)
    await send("hello", to: model)
    terminal.written = []
    model.readScreen = { [weak model] in
      await MainActor.run { model?.activity = .awaitingUser(.approval) }
      return Self.queuedScreen
    }
    await model.sendNow()
    #expect(terminal.written.isEmpty)
  }

  @Test("The prompts the transcript writes once sent confirm both echoes")
  func confirmedByTranscript() async {
    let model = model(terminal: Terminal())
    await send("first", to: model)
    await send("second", to: model)
    await model.sendNow()
    model.apply(
      ConversationSnapshot(
        entries: [
          ConversationEntry(id: "i", content: .notice(.interrupted)),
          ConversationEntry(id: "1", content: .userPrompt("first", attachments: [])),
          ConversationEntry(id: "2", content: .userPrompt("second", attachments: [])),
        ], availability: .available))
    #expect(model.echoes.isEmpty)
    #expect(model.sendNowEchoID == nil)
  }
}
