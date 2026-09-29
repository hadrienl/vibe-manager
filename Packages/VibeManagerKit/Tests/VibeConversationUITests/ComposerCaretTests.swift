import AppKit
import Testing

@testable import VibeConversationUI

@Suite("↑ and ↓ recall only from the first and the last line (#123)")
@MainActor
struct ComposerCaretTests {
  @Test("Lines as the text breaks them")
  func logical() {
    #expect(
      ComposerCaret.logical(text: "", cursor: 0) == .init(isOnFirstLine: true, isOnLastLine: true))
    #expect(
      ComposerCaret.logical(text: "one", cursor: 1)
        == .init(isOnFirstLine: true, isOnLastLine: true))
    let three = "one\ntwo\nthree"
    #expect(
      ComposerCaret.logical(text: three, cursor: 3)
        == .init(isOnFirstLine: true, isOnLastLine: false))
    #expect(
      ComposerCaret.logical(text: three, cursor: 5)
        == .init(isOnFirstLine: false, isOnLastLine: false))
    #expect(
      ComposerCaret.logical(text: three, cursor: 8)
        == .init(isOnFirstLine: false, isOnLastLine: true))
    #expect(
      ComposerCaret.logical(text: "one\n", cursor: 4)
        == .init(isOnFirstLine: false, isOnLastLine: true))
  }

  /// A text view never put on screen, as narrow as a small composer.
  /// In TextKit 2, as a text editor is, or in TextKit 1, where a view can fall back.
  private func textView(_ text: String, cursor: Int, textKit2: Bool = true) -> NSTextView {
    let view = NSTextView(usingTextLayoutManager: textKit2)
    view.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
    view.font = .systemFont(ofSize: 13)
    view.string = text
    view.setSelectedRange(NSRange(location: cursor, length: 0))
    return view
  }

  @Test(
    "A long message without a line break spans several lines, as drawn", arguments: [true, false])
  func wrapped(textKit2: Bool) throws {
    let text = String(repeating: "word ", count: 40)
    let length = (text as NSString).length
    #expect((textView(text, cursor: 0, textKit2: textKit2).textLayoutManager != nil) == textKit2)
    let start = try #require(ComposerCaret(textView: textView(text, cursor: 2, textKit2: textKit2)))
    #expect(start.isOnFirstLine && !start.isOnLastLine)
    let middle = try #require(
      ComposerCaret(textView: textView(text, cursor: length / 2, textKit2: textKit2)))
    #expect(!middle.isOnFirstLine && !middle.isOnLastLine)
    let end = try #require(
      ComposerCaret(textView: textView(text, cursor: length, textKit2: textKit2)))
    #expect(!end.isOnFirstLine && end.isOnLastLine)
  }

  @Test(
    "Line breaks, an empty last line, a single line and an empty field", arguments: [true, false])
  func breaks(textKit2: Bool) throws {
    let lines = "one\ntwo\n"
    let first = try #require(
      ComposerCaret(textView: textView(lines, cursor: 3, textKit2: textKit2)))
    #expect(first.isOnFirstLine && !first.isOnLastLine)
    let second = try #require(
      ComposerCaret(textView: textView(lines, cursor: 7, textKit2: textKit2)))
    #expect(!second.isOnFirstLine && !second.isOnLastLine)
    let empty = try #require(
      ComposerCaret(textView: textView(lines, cursor: 8, textKit2: textKit2)))
    #expect(!empty.isOnFirstLine && empty.isOnLastLine)
    let single = try #require(
      ComposerCaret(textView: textView("one", cursor: 0, textKit2: textKit2)))
    #expect(single.isOnFirstLine && single.isOnLastLine)
    let blank = try #require(ComposerCaret(textView: textView("", cursor: 0, textKit2: textKit2)))
    #expect(blank.isOnFirstLine && blank.isOnLastLine)
  }

  @Test("Text selected: the arrow collapses it, and recalls nothing")
  func selection() {
    let view = textView("one", cursor: 0)
    view.setSelectedRange(NSRange(location: 0, length: 2))
    #expect(ComposerCaret(textView: view) == nil)
  }
}
