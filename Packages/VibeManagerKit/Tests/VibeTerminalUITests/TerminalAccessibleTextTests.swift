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

  @Test("The view answers VoiceOver from the whole buffer, insertion point at the cursor")
  func viewAnswers() {
    let view = AccessibleTerminalView()
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
    #expect(view.accessibilityValue() as? String == "first\nsecond line")
  }

  private func focusedView() -> (AccessibleTerminalView, NSWindow) {
    // Never put on screen: the tests do not show windows.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
      backing: .buffered, defer: true)
    let view = AccessibleTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
  }

  @Test("A burst of output is told once, the rest waiting for the interval")
  func burstToldOnce() {
    let (view, window) = focusedView()
    view.announcementInterval = .seconds(3600)
    var told: [NSAccessibility.Notification] = []
    view.onAnnouncement = { told.append($0) }

    for chunk in 0..<10 {
      view.getTerminal().feed(text: "chunk \(chunk)\r\n")
      view.textDidChange()
    }

    #expect(told == [.valueChanged, .selectedTextChanged])
    #expect(view.pendingAnnouncement != nil)
    view.pendingAnnouncement?.cancel()
    withExtendedLifetime(window) {}
  }

  @Test("Nothing is told for a terminal without the focus, or put away")
  func silentWhenNotRead() {
    let (view, window) = focusedView()
    var told: [NSAccessibility.Notification] = []
    view.onAnnouncement = { told.append($0) }

    view.isHidden = true
    view.textDidChange()
    view.isHidden = false
    window.makeFirstResponder(nil)
    view.textDidChange()

    #expect(told.isEmpty)
    withExtendedLifetime(window) {}
  }
}
