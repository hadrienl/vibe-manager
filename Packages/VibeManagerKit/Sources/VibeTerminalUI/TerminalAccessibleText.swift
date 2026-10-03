import Foundation
import SwiftTerm

/// What VoiceOver reads of a terminal: its history, then its screen, one line per row, with the
/// insertion point at the cursor. Ranges count UTF-16 units, as the accessibility API does.
struct TerminalAccessibleText {
  let string: String
  /// The first character of each line; a line runs to the next one, its newline included.
  private let lineStarts: [Int]
  /// The lines the view shows: the screen, or the part of the history scrolled back to.
  let visibleLines: Range<Int>
  let insertionPoint: Int

  init(lines: [String], visibleLines: Range<Int>, cursor: (line: Int, column: Int)) {
    let lines = lines.isEmpty ? [""] : lines
    var starts: [Int] = []
    var offset = 0
    for line in lines {
      starts.append(offset)
      offset += line.utf16.count + 1
    }
    string = lines.joined(separator: "\n")
    lineStarts = starts
    let last = lines.count
    self.visibleLines =
      min(visibleLines.lowerBound, last - 1)..<max(min(visibleLines.upperBound, last), 1)
    let line = min(max(cursor.line, 0), lines.count - 1)
    let column = min(max(cursor.column, 0), lines[line].utf16.count)
    insertionPoint = starts[line] + column
  }

  /// Reads the whole buffer of `terminal`: every line of history SwiftTerm still keeps, then the
  /// screen, without the blank rows below both the cursor and the last thing written.
  init(terminal: Terminal) {
    let buffer = terminal.buffer
    var rows: [String] = []
    var cursorColumn = 0
    let top = buffer.totalLinesTrimmed
    while let line = terminal.getScrollInvariantLine(row: top + rows.count) {
      rows.append(Self.text(of: line, in: terminal, trimRight: true))
    }
    let history = max(0, rows.count - terminal.rows)
    let cursorLine = history + buffer.y
    if let line = terminal.getScrollInvariantLine(row: top + cursorLine) {
      cursorColumn = Self.text(of: line, in: terminal, trimRight: false, upTo: buffer.x).utf16.count
    }
    let lastWritten = rows.lastIndex { !$0.isEmpty } ?? 0
    let kept = max(lastWritten, cursorLine) + 1
    rows.removeLast(max(0, rows.count - kept))
    let firstShown = buffer.yDisp
    self.init(
      lines: rows, visibleLines: firstShown..<(firstShown + terminal.rows),
      cursor: (cursorLine, cursorColumn))
  }

  /// One reading of a row for both the line and the cursor: the empty cell a wide character
  /// leaves behind is skipped, so an emoji or a CJK character counts as itself, not as two. The
  /// terminal names the characters a cell only refers to, an emoji among them.
  private static func text(
    of line: BufferLine, in terminal: Terminal, trimRight: Bool, upTo column: Int = -1
  ) -> String {
    line.translateToString(
      trimRight: trimRight, startCol: 0, endCol: column, skipNullCellsFollowingWide: true,
      characterProvider: { terminal.getCharacter(for: $0) }
    )
    .replacingOccurrences(of: "\u{0}", with: " ")
  }

  var length: Int { string.utf16.count }

  var lineCount: Int { lineStarts.count }

  /// The line holding the character at `index`; past the end, the last line.
  func line(for index: Int) -> Int {
    guard index > 0 else { return 0 }
    var low = 0
    var high = lineStarts.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if lineStarts[middle] <= index { low = middle } else { high = middle - 1 }
    }
    return low
  }

  /// The characters of `line`, its newline included, as a text view reports them.
  func range(forLine line: Int) -> NSRange {
    guard lineStarts.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
    let start = lineStarts[line]
    let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
    return NSRange(location: start, length: end - start)
  }

  func string(for range: NSRange) -> String? {
    guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
      range.location + range.length <= length
    else { return nil }
    return (string as NSString).substring(with: range)
  }

  var visibleRange: NSRange {
    let start = range(forLine: visibleLines.lowerBound).location
    let last = range(forLine: visibleLines.upperBound - 1)
    return NSRange(location: start, length: last.location + last.length - start)
  }
}
