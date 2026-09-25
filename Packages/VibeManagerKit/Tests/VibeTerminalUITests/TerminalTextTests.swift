import SwiftTerm
import Testing

@testable import VibeTerminalUI

@Suite("Terminal text for VoiceOver")
struct TerminalTextTests {
  private final class Delegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
  }

  @Test("The last lines are what a program showed: colours, titles and rewrites removed")
  func lastLines() {
    let output =
      "\u{1B}]0;agent title\u{07}first line\r\n"
      + "\u{1B}[1;32mgreen\u{1B}[0m and plain\r\n\r\n"
      + "progress 10%\rprogress 100%\r\n"
      + "\u{1B}[?25l\u{1B}[2Klast\r\n   \r\n"

    let lines = TerminalText.lastLines(of: Array(output.utf8), count: 5)

    #expect(lines == ["first line", "green and plain", "progress 100%", "last"])
    #expect(TerminalText.lastLines(of: Array(output.utf8), count: 2) == ["progress 100%", "last"])
    #expect(TerminalText.lastLines(of: [], count: 5).isEmpty)
  }

  @Test("The screen is the visible lines, without the trailing blank ones")
  func visibleScreen() {
    let terminal = Terminal(
      delegate: Delegate(), options: TerminalOptions(cols: 40, rows: 6, scrollback: 100))
    terminal.feed(text: "one\r\n\u{1B}[31mtwo\u{1B}[0m   \r\n")

    #expect(TerminalText.visibleScreen(of: terminal) == "one\ntwo")
  }

  @MainActor
  @Test("The terminal view is one read-only text area named after its session")
  func accessibleView() {
    let view = AccessibleTerminalView()
    view.accessibilityTitle = "Terminal — Refactor — Running"
    view.getTerminal().feed(text: "hello\r\n")

    #expect(view.isAccessibilityElement())
    #expect(view.accessibilityRole() == .textArea)
    #expect(view.accessibilityLabel() == "Terminal — Refactor — Running")
    #expect((view.accessibilityValue() as? String)?.hasPrefix("hello") == true)
  }
}
