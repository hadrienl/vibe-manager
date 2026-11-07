import Foundation
import Testing
import VibeApplication

@testable import VibeTerminalUI

@Suite("A terminal's screen, replayed from its history (#273)")
struct TerminalScreenReplayTests {
  @Test("What was redrawn in place reads as it ends, as a dialog is drawn over the prompt")
  func redrawn() {
    // A prompt, then the lines rewritten from the cursor up, the way an interface redraws.
    let history = Array(
      "$ claude\r\n❯ Type here\r\n\u{1B}[1A\u{1B}[2K ❯ 1. Yes\r\n   2. No\r\n Esc to cancel".utf8)
    let screen = TerminalText.screen(
      replaying: history, size: TerminalSize(columns: 40, rows: 10))
    #expect(screen == "$ claude\n ❯ 1. Yes\n   2. No\n Esc to cancel")
    #expect(AgentDialogScreen(screen: screen)?.options.map(\.label) == ["Yes", "No"])
  }

  @Test("Read again and again, the screen is the replayed one, only the new output fed (#411)")
  func followed() async {
    let size = TerminalSize(columns: 40, rows: 6)
    let first = Array((0..<50).map { "line \($0)\r\n" }.joined().utf8)
    let more = Array("\u{1B}[2A\u{1B}[2K › 1. Low\r\n   2. High".utf8)
    let follower = TerminalScreenFollower()

    let opened = await follower.screen(
      of: TerminalHistorySnapshot(bytes: first, droppedByteCount: 0), size: size)
    #expect(opened == TerminalText.screen(replaying: first, size: size))
    let drawn = await follower.screen(
      of: TerminalHistorySnapshot(bytes: first + more, droppedByteCount: 0), size: size)
    #expect(drawn == TerminalText.screen(replaying: first + more, size: size))
    #expect(drawn.hasSuffix(" › 1. Low\n   2. High"))

    // Output dropped past what was fed: the history left is replayed whole.
    let kept = Array("\u{1B}[2J\u{1B}[H› Ask".utf8)
    let dropped = await follower.screen(
      of: TerminalHistorySnapshot(
        bytes: kept, droppedByteCount: 10_000, startOffset: first.count + more.count + 5_000),
      size: size)
    #expect(dropped == TerminalText.screen(replaying: kept, size: size))
  }

  /// Claude Code 2.1, at rest: its prompt between two rules, as it draws it (#464).
  private static func prompt(_ content: String) -> [UInt8] {
    let rule = String(repeating: "─", count: 30)
    return Array(
      "Done.\r\n\(rule)\r\n❯\u{A0}\(content)\u{1B}[0m\r\n\(rule)\r\n  ? for shortcuts".utf8)
  }

  @Test("What the agent shows greyed in its prompt is no text typed into it (#464)")
  func dimTextIsNoInput() {
    let size = TerminalSize(columns: 40, rows: 10)
    // A suggested answer, drawn dim as Claude Code draws `Try "…"`.
    let suggested = TerminalText.screens(
      replaying: Self.prompt("\u{1B}[2myes, push it"), size: size)
    #expect(suggested.shown.contains("❯\u{A0}yes, push it"))
    let input = PromptInputRecognition.input(screen: suggested.undimmed)
    #expect(input != nil)
    #expect(PromptInputRecognition.holdsText(input ?? ["x"]) == false)

    // The same words typed by the user are text, in Claude Code's white.
    let typed = TerminalText.screens(
      replaying: Self.prompt("\u{1B}[38;2;255;255;255myes, push it"), size: size)
    #expect(typed.undimmed == typed.shown)
    #expect(
      PromptInputRecognition.input(screen: typed.undimmed).map(PromptInputRecognition.holdsText)
        == true)
  }

  @Test("The follower reads the screen with and without its dim text (#464)")
  func followedUndimmed() async {
    let size = TerminalSize(columns: 40, rows: 10)
    let bytes = Self.prompt("\u{1B}[2mTry \"fix lint errors\"")
    let screens = await TerminalScreenFollower().screens(
      of: TerminalHistorySnapshot(bytes: bytes, droppedByteCount: 0), size: size)
    #expect(screens == TerminalText.screens(replaying: bytes, size: size))
    #expect(!screens.undimmed.contains("Try"))
  }
}
