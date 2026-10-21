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
}
