import AppKit
import SwiftTerm
import Testing

@testable import VibeTerminalUI

@MainActor
@Suite("The terminal as a text area for VoiceOver")
struct TerminalAccessibleTextTests {
  private final class Delegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
  }

  /// Six lines on a four-row screen: two in the history, four on screen, the cursor after "six".
  private func terminal() -> Terminal {
    let terminal = Terminal(
      delegate: Delegate(), options: TerminalOptions(cols: 20, rows: 4, scrollback: 100))
    terminal.feed(text: "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix")
    return terminal
  }

  @Test("Lines, ranges and strings cover the history and the screen")
  func linesAndRanges() {
    let text = TerminalAccessibleText(terminal: terminal())

    #expect(text.string == "one\ntwo\nthree\nfour\nfive\nsix")
    #expect(text.lineCount == 6)
    #expect(text.line(for: 0) == 0)
    #expect(text.line(for: 4) == 1)
    #expect(text.line(for: 8) == 2)
    #expect(text.line(for: text.length) == 5)
    #expect(text.range(forLine: 1) == NSRange(location: 4, length: 4))
    #expect(text.range(forLine: 5) == NSRange(location: 24, length: 3))
    #expect(text.string(for: text.range(forLine: 2)) == "three\n")
    #expect(text.string(for: NSRange(location: 0, length: 3)) == "one")
    #expect(text.string(for: NSRange(location: 26, length: 10)) == nil)
    #expect(text.visibleRange == NSRange(location: 8, length: 19))
    #expect(text.insertionPoint == 27)
  }

  @Test("A cursor after wide characters stands where the line's text puts it")
  func wideCharacters() {
    let terminal = Terminal(
      delegate: Delegate(), options: TerminalOptions(cols: 20, rows: 4, scrollback: 100))
    terminal.feed(text: "a😀中b")

    let text = TerminalAccessibleText(terminal: terminal)

    #expect(text.string == "a😀中b")
    #expect(text.insertionPoint == text.length)
    #expect(text.string(for: NSRange(location: 0, length: text.insertionPoint)) == "a😀中b")
  }

  @Test("The view answers VoiceOver from the whole buffer, insertion point at the cursor")
  func viewAnswers() {
    let view = AccessibleTerminalView()
    var now = ContinuousClock.now
    view.clock = { now }
    view.getTerminal().feed(text: "first\r\nsecond")
    view.textDidChange()

    #expect(view.accessibilityNumberOfCharacters() == 12)
    #expect(view.accessibilityLine(for: 7) == 1)
    #expect(view.accessibilityRange(forLine: 0) == NSRange(location: 0, length: 6))
    #expect(view.accessibilityString(for: NSRange(location: 6, length: 6)) == "second")
    #expect(view.accessibilitySelectedTextRange() == NSRange(location: 12, length: 0))
    #expect(view.accessibilityInsertionPointLineNumber() == 1)

    view.getTerminal().feed(text: " line")
    view.textDidChange()
    now += .seconds(2)
    #expect(view.accessibilityValue() as? String == "first\nsecond line")
  }

  @Test("Output pouring in reads the history again at most once per interval")
  func rebuildsAtMostOncePerInterval() {
    let view = AccessibleTerminalView()
    var now = ContinuousClock.now
    view.clock = { now }
    _ = view.accessibilityValue()
    #expect(view.textBuilds == 1)

    for chunk in 0..<20 {
      view.getTerminal().feed(text: "chunk \(chunk)\r\n")
      view.textDidChange()
      _ = view.accessibilityValue()
      _ = view.accessibilityNumberOfCharacters()
      now += .milliseconds(40)
    }
    #expect(view.textBuilds == 1)

    now += .seconds(1)
    #expect((view.accessibilityValue() as? String)?.contains("chunk 19") == true)
    #expect(view.textBuilds == 2)

    _ = view.accessibilityValue()
    #expect(view.textBuilds == 2)
  }

  @Test("A new size is read again at once, whatever changed it")
  func newSizeReadAtOnce() {
    let view = AccessibleTerminalView()
    let now = ContinuousClock.now
    view.clock = { now }
    view.getTerminal().feed(text: "hello")
    _ = view.accessibilityValue()

    view.getTerminal().resize(cols: 40, rows: 10)
    _ = view.accessibilityValue()

    #expect(view.textBuilds == 2)
  }
}
