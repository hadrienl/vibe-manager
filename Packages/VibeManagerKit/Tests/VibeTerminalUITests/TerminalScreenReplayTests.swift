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
}
