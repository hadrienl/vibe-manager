import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

@MainActor
@Suite("A prompt is not typed into a dialog its terminal shows (#319)")
struct DialogOnScreenTests {
  /// Drawn as Claude Code draws its dialogs: numbered options, a pointer, the keys that close it.
  static let dialog = """
    Auto mode setup
    ❯ 1. Yes, set it up
      2. Not now
    Enter to confirm · Esc to cancel
    """
  static let atRest = "────\n❯ \n────\n  ⏵⏵ auto mode on (shift+tab to cycle)"

  private final class Screen: @unchecked Sendable {
    var text: String?
    var written: [[UInt8]] = []
  }

  private func model(screen: Screen) -> ConversationModel {
    let model = ConversationModel(sessionID: SessionID())
    model.write = { screen.written.append($0) }
    model.readScreen = { screen.text }
    model.processRunning = { true }
    model.promptFormat = AgentPromptFormat(
      textEntry: .plain, submitDelay: .zero, shellEntry: ShellEntry(switchDelay: .zero))
    model.apply(ConversationSnapshot(entries: [], availability: .available))
    return model
  }

  private func until(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition(), !Task.isCancelled { await Task.yield() }
  }

  @Test("A dialog on screen: nothing typed, the draft kept, the dialog shown in the conversation")
  func dialogHoldsThePrompt() async {
    let screen = Screen()
    screen.text = Self.dialog
    let model = model(screen: screen)
    model.draft = "The workspace is meant to be independent"
    #expect(await model.send() == false)
    #expect(screen.written.isEmpty)
    #expect(model.echoes.isEmpty)
    #expect(model.draft == "The workspace is meant to be independent")
    #expect(model.terminalPanel == ConversationModel.TerminalPanel(echoID: nil, command: nil))
    // The panel open, keys typed now would go to it.
    #expect(!model.canSend)
  }

  @Test("A command for the shell is held as well")
  func shellCommandHeld() async {
    let screen = Screen()
    screen.text = Self.dialog
    let model = model(screen: screen)
    model.draft = "!git status"
    #expect(await model.send() == false)
    #expect(screen.written.isEmpty)
    #expect(model.draft == "!git status")
  }

  @Test(
    "The dialog answered, the block goes and the draft can be sent", .timeLimit(.minutes(1)))
  func dialogAnswered() async {
    let screen = Screen()
    screen.text = Self.dialog
    let model = model(screen: screen)
    model.draft = "hello"
    #expect(await model.send() == false)
    // Already seen: the block does not wait to find it before it can close.
    model.terminalScreenChanged(Self.atRest)
    await until { model.terminalPanel == nil }
    #expect(model.draft == "hello")
    #expect(model.canSend)
    screen.text = Self.atRest
    #expect(await model.send())
    #expect(!screen.written.isEmpty)
    #expect(model.draft.isEmpty)
  }

  @Test("A prompt at rest, a turn under way, or a screen that cannot be read: typed as before")
  func noDialog() async {
    for text in [Self.atRest, "✻ Thinking… (esc to interrupt)", nil] {
      let screen = Screen()
      screen.text = text
      let model = model(screen: screen)
      model.draft = "hello"
      #expect(await model.send())
      #expect(!screen.written.isEmpty)
      #expect(model.terminalPanel == nil)
    }
  }

  @Test("The agent's last words naming Escape, above the prompt at rest: typed as before")
  func agentWordsAreNoDialog() async {
    let screen = Screen()
    screen.text = "Then press Esc to exit the editor.\n" + Self.atRest
    let model = model(screen: screen)
    model.draft = "hello"
    #expect(await model.send())
    #expect(!screen.written.isEmpty)
    #expect(model.terminalPanel == nil)
  }

  @Test("A request reported while the screen is read: nothing typed into its dialog")
  func requestWhileReading() async {
    let screen = Screen()
    let model = model(screen: screen)
    model.readScreen = { [weak model] in
      await MainActor.run { model?.activity = .awaitingUser(.approval) }
      return Self.atRest
    }
    model.draft = "hello"
    #expect(await model.send() == false)
    #expect(screen.written.isEmpty)
    #expect(model.echoes.isEmpty)
    #expect(model.draft == "hello")
  }

  @Test("A panel open in the conversation holds the composer", .timeLimit(.minutes(1)))
  func panelHoldsTheComposer() async {
    let screen = Screen()
    screen.text = Self.atRest
    let model = model(screen: screen)
    model.draft = "/mcp"
    #expect(await model.send())
    await until { model.terminalPanel != nil }
    model.draft = "hello"
    #expect(!model.canSend)
    #expect(await model.send() == false)
  }
}
