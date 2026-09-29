import AppKit

/// Whether the insertion point is on the first or the last line of the composer, as ↑ and ↓ ask
/// before they recall a message rather than move it (#123).
///
/// Lines as drawn: a long message without a line break spans several, and ↑ on its third one moves
/// up, as the arrow always does. Read from the composer's text view — `TextSelection` needs
/// macOS 15.
struct ComposerCaret: Hashable {
  let isOnFirstLine: Bool
  let isOnLastLine: Bool

  /// The composer's text view, when it has the keyboard and shows `draft`.
  @MainActor static func current(showing draft: String) -> ComposerCaret? {
    guard let textView = PromptComposer.focusedTextView(), textView.string == draft
    else { return nil }
    return ComposerCaret(textView: textView)
  }

  /// `nil` while text is selected: the arrow then collapses the selection, as it always does.
  @MainActor init?(textView: NSTextView) {
    let selection = textView.selectedRange()
    guard selection.length == 0 else { return nil }
    let text = textView.string as NSString
    guard let lines = Self.lines(of: textView), !lines.isEmpty else {
      self = Self.logical(text: textView.string, cursor: selection.location)
      return
    }
    let cursor = selection.location
    // A text ending with a line break ends with an empty line, which no fragment holds.
    let endsWithEmptyLine = text.length > 0 && text.character(at: text.length - 1) == 0x0A
    isOnFirstLine = (lines.count == 1 && !endsWithEmptyLine) || cursor < lines[0].upperBound
    isOnLastLine =
      endsWithEmptyLine ? cursor == text.length : cursor >= lines[lines.count - 1].location
  }

  init(isOnFirstLine: Bool, isOnLastLine: Bool) {
    self.isOnFirstLine = isOnFirstLine
    self.isOnLastLine = isOnLastLine
  }

  /// Lines as the text breaks them, when there is no layout to read.
  static func logical(text: String, cursor: Int) -> ComposerCaret {
    let text = text as NSString
    let cursor = min(max(cursor, 0), text.length)
    let before = text.range(
      of: "\n", options: .backwards, range: NSRange(location: 0, length: cursor))
    let after = text.range(
      of: "\n", range: NSRange(location: cursor, length: text.length - cursor))
    return ComposerCaret(
      isOnFirstLine: before.location == NSNotFound, isOnLastLine: after.location == NSNotFound)
  }

  /// The ranges of the lines drawn, in the text's UTF-16 offsets, in order.
  @MainActor private static func lines(of textView: NSTextView) -> [NSRange]? {
    if let layout = textView.textLayoutManager {
      guard let content = layout.textContentManager else { return nil }
      let document = layout.documentRange
      layout.ensureLayout(for: document)
      var lines: [NSRange] = []
      layout.enumerateTextLayoutFragments(from: document.location, options: [.ensuresLayout]) {
        fragment in
        let start = content.offset(from: document.location, to: fragment.rangeInElement.location)
        for line in fragment.textLineFragments where line.characterRange.length > 0 {
          lines.append(
            NSRange(
              location: start + line.characterRange.location, length: line.characterRange.length))
        }
        return true
      }
      return lines
    }
    // Only a view already in TextKit 1: reading `layoutManager` would move one there.
    guard let layout = textView.layoutManager, let container = textView.textContainer else {
      return nil
    }
    layout.ensureLayout(for: container)
    var lines: [NSRange] = []
    layout.enumerateLineFragments(
      forGlyphRange: layout.glyphRange(for: container)
    ) { _, _, _, glyphs, _ in
      lines.append(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
    }
    return lines
  }
}
