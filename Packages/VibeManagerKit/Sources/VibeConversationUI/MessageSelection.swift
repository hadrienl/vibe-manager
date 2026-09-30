import AppKit
import SwiftUI

/// A place in a message's text: one of its segments, in reading order, and an offset in it.
struct SelectionPosition: Comparable {
  var segment: Int
  var offset: Int

  static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.segment, lhs.offset) < (rhs.segment, rhs.offset)
  }
}

/// One selection per message (#189).
///
/// A message is drawn by several text views — its prose, each code block, each table — and AppKit
/// keeps a selection per view. The message's selection tracks the drag itself, from one view to the
/// next, gives each the part it draws, and puts the passage together, in the message's order, when
/// it is copied.
@MainActor
final class MessageSelection {
  private struct Member {
    weak var view: SegmentTextView?
  }

  private var members: [Member] = []
  /// The events that follow a click, until the button is released: the window's; a test gives
  /// its own.
  static var nextEvent: (NSWindow) -> NSEvent? = {
    $0.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic])
  }
  /// Where the selection started, for ⇧-click to extend it.
  private weak var anchorView: SegmentTextView?
  /// While it sets its segments' ranges itself, rather than a segment on its own.
  private(set) var applying = false
  private var anchorOffset = 0

  func register(_ view: SegmentTextView) {
    members.removeAll { $0.view == nil }
    guard !members.contains(where: { $0.view === view }) else { return }
    members.append(Member(view: view))
  }

  func unregister(_ view: SegmentTextView) {
    members.removeAll { $0.view == nil || $0.view === view }
  }

  /// In reading order: from the top, then from the leading edge. SwiftUI makes the views in any
  /// order, and a code block in a list item is read where it is drawn.
  var segments: [SegmentTextView] {
    let views = members.compactMap(\.view)
    guard views.allSatisfy({ $0.window != nil }) else { return views }
    let frames = views.map { $0.convert($0.bounds, to: nil) }
    return zip(views, frames).sorted { first, second in
      if abs(first.1.maxY - second.1.maxY) > 0.5 { return first.1.maxY > second.1.maxY }
      return first.1.minX < second.1.minX
    }.map(\.0)
  }

  /// Whether its selection is the one the keyboard acts on: its window is key, and one of its
  /// segments holds the keyboard.
  var isActive: Bool {
    guard let window = members.lazy.compactMap(\.view).first?.window, window.isKeyWindow else {
      return false
    }
    return members.contains { $0.view != nil && $0.view === window.firstResponder }
  }

  var window: NSWindow? {
    members.lazy.compactMap(\.view?.window).first
  }

  var hasSelection: Bool {
    members.contains { ($0.view?.selectedRange().length ?? 0) > 0 }
  }

  // MARK: Selecting

  /// Follows a drag that started with `event` in `view`, until the button is released.
  func track(_ event: NSEvent, in view: SegmentTextView) {
    let segments = segments
    guard let window = view.window, segments.contains(where: { $0 === view }) else {
      return
    }
    SelectionOwner.shared.claim(self)
    var start = Self.position(at: event.locationInWindow, in: segments)
    if event.modifierFlags.contains(.shift), let anchorView,
      let anchor = segments.firstIndex(where: { $0 === anchorView })
    {
      start = SelectionPosition(
        segment: anchor, offset: min(anchorOffset, anchorView.textLength))
    } else {
      anchorView = segments[start.segment]
      anchorOffset = start.offset
    }
    let clicked = view.clickedLink(at: event.locationInWindow)
    select(from: start, to: Self.position(at: event.locationInWindow, in: segments), segments)
    window.makeFirstResponder(view)

    // Periodic events keep scrolling while the pointer rests beyond the conversation's edge.
    NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
    defer { NSEvent.stopPeriodicEvents() }
    var last = event
    var moved = false
    while let next = Self.nextEvent(window) {
      switch next.type {
      case .leftMouseUp:
        if !moved, let clicked {
          // A click, not a drag, on a link opens it; a drag that starts on one only selects.
          select(from: start, to: start, segments)
          view.clicked(onLink: clicked.link, at: clicked.index)
        }
        return
      case .leftMouseDragged:
        let distance = hypot(
          next.locationInWindow.x - event.locationInWindow.x,
          next.locationInWindow.y - event.locationInWindow.y)
        if distance > 3 { moved = true }
        last = next
      default:
        guard moved else { continue }
      }
      if moved { Self.autoscroll(view, with: last) }
      select(from: start, to: Self.position(at: last.locationInWindow, in: segments), segments)
    }
  }

  /// A double or triple click chose a word or a paragraph in `view`, on its own.
  func selectedWithin(_ view: SegmentTextView) {
    SelectionOwner.shared.claim(self)
    clear(except: view)
    anchorView = view
    anchorOffset = view.selectedRange().location
  }

  func selectAll() {
    let segments = segments
    guard let last = segments.last else { return }
    SelectionOwner.shared.claim(self)
    anchorView = segments.first
    anchorOffset = 0
    select(
      from: SelectionPosition(segment: 0, offset: 0),
      to: SelectionPosition(segment: segments.count - 1, offset: last.textLength), segments)
  }

  func clear(except kept: SegmentTextView? = nil) {
    applying = true
    defer { applying = false }
    for view in members.compactMap(\.view) where view !== kept && view.selectedRange().length > 0 {
      view.setSelectedRange(NSRange(location: view.selectedRange().location, length: 0))
    }
  }

  /// Redrawn when it becomes, or stops being, the active selection: the segments without the
  /// keyboard draw it in the same colour as the one with it (`SegmentLayoutManager`).
  func redisplay() {
    for view in members.compactMap(\.view) where view.selectedRange().length > 0 {
      view.needsDisplay = true
    }
  }

  private func select(
    from start: SelectionPosition, to end: SelectionPosition, _ segments: [SegmentTextView]
  ) {
    let ranges = Self.ranges(from: start, to: end, lengths: segments.map(\.textLength))
    applying = true
    defer { applying = false }
    for (view, range) in zip(segments, ranges) where view.selectedRange() != range {
      view.setSelectedRange(range)
    }
  }

  // MARK: Copying

  /// The selected passage, segment by segment, in reading order.
  var selectedPieces: [SelectionText.Piece] {
    segments.compactMap { view in
      let range = view.selectedRange()
      guard range.length > 0, let storage = view.textStorage else { return nil }
      return SelectionText.Piece(
        kind: view.kind, text: storage.attributedSubstring(from: range))
    }
  }

  /// Writes the passage as plain and rich text. `false` when nothing is selected.
  @discardableResult
  func copy(to pasteboard: NSPasteboard) -> Bool {
    let pieces = selectedPieces
    guard !pieces.isEmpty else { return false }
    pasteboard.clearContents()
    let rich = SelectionText.rich(pieces)
    if let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])
    {
      pasteboard.setData(rtf, forType: .rtf)
    }
    pasteboard.setString(SelectionText.plain(pieces), forType: .string)
    return true
  }

  // MARK: Geometry

  /// Where a point of the window falls among segments sorted in reading order: in one of them,
  /// or, between two, at the start of the next — a rule, a margin, a code block's header.
  static func position(at point: NSPoint, in segments: [SegmentTextView]) -> SelectionPosition {
    let frames = segments.map { $0.convert($0.bounds, to: nil) }
    switch hit(y: point.y, frames: frames) {
    case .start(let index):
      return SelectionPosition(segment: index, offset: 0)
    case .end(let index):
      return SelectionPosition(segment: index, offset: segments[index].textLength)
    case .inside(let index):
      let view = segments[index]
      var local = view.convert(point, from: nil)
      // Within what shows of a code block scrolled sideways, not the whole of its longest line.
      let visible = view.visibleRect.isEmpty ? view.bounds : view.visibleRect
      local.x = min(max(local.x, visible.minX), visible.maxX)
      local.y = min(max(local.y, 0), view.bounds.height)
      return SelectionPosition(segment: index, offset: view.characterIndexForInsertion(at: local))
    }
  }

  enum Hit: Equatable {
    case start(Int)
    case inside(Int)
    case end(Int)
  }

  /// `frames` in the window's coordinates, whose y goes up, and in reading order.
  static func hit(y: CGFloat, frames: [CGRect]) -> Hit {
    for (index, frame) in frames.enumerated() {
      if y > frame.maxY { return .start(index) }
      if y >= frame.minY { return .inside(index) }
    }
    return .end(max(frames.count - 1, 0))
  }

  /// What each segment selects between two positions, in either order: everything between them,
  /// the two ends partly.
  static func ranges(from start: SelectionPosition, to end: SelectionPosition, lengths: [Int])
    -> [NSRange]
  {
    let (low, high) = start <= end ? (start, end) : (end, start)
    return lengths.enumerated().map { index, length in
      let from = index == low.segment ? min(low.offset, length) : 0
      let to = index == high.segment ? min(high.offset, length) : length
      guard index >= low.segment, index <= high.segment, to > from else {
        return NSRange(location: index == low.segment ? from : 0, length: 0)
      }
      return NSRange(location: from, length: to - from)
    }
  }

  private static func autoscroll(_ view: NSView, with event: NSEvent) {
    // The innermost scroll view — a code block's, sideways — then the conversation's.
    var scrollView = view.enclosingScrollView
    while let current = scrollView {
      current.contentView.autoscroll(with: event)
      scrollView = current.enclosingScrollView
    }
  }
}

/// Makes sure only one selection shows in a window: starting one clears the one before, in
/// another message or in this one. Another window keeps its own, as macOS does.
@MainActor
final class SelectionOwner {
  static let shared = SelectionOwner()

  private struct Owner {
    weak var window: NSWindow?
    weak var selection: MessageSelection?
  }

  private var owners: [Owner] = []

  func claim(_ selection: MessageSelection) {
    owners.removeAll { $0.window == nil || $0.selection == nil }
    guard let window = selection.window else { return }
    if let index = owners.firstIndex(where: { $0.window === window }) {
      if let current = owners[index].selection, current !== selection { current.clear() }
      owners[index].selection = selection
    } else {
      owners.append(Owner(window: window, selection: selection))
    }
  }
}

/// The text a passage copies, put together from its segments.
enum SelectionText {
  struct Piece {
    var kind: SegmentKind
    var text: NSAttributedString
  }

  /// A blank line between segments; code as it is; a table as tab-separated lines, which a
  /// spreadsheet reads.
  static func plain(_ pieces: [Piece]) -> String {
    pieces.map { piece in
      piece.kind == .table ? tabulated(piece.text) : piece.text.string
    }
    .filter { !$0.isEmpty }
    .joined(separator: "\n\n")
  }

  /// The same, with its fonts, emphasis, links and tables, but none of the theme's colours: a
  /// dark theme pasted into a white page would be white on white.
  static func rich(_ pieces: [Piece]) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for piece in pieces {
      if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
      let text = NSMutableAttributedString(attributedString: piece.text)
      let whole = NSRange(location: 0, length: text.length)
      text.removeAttribute(.foregroundColor, range: whole)
      text.removeAttribute(.backgroundColor, range: whole)
      text.removeAttribute(.quoteBars, range: whole)
      text.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
        guard let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty,
          let neutral = style.mutableCopy() as? NSMutableParagraphStyle
        else { return }
        neutral.textBlocks = style.textBlocks.map { block in
          let copy = (block.copy() as? NSTextBlock) ?? block
          copy.backgroundColor = nil
          for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            copy.setBorderColor(.gray, for: edge)
          }
          return copy
        }
        text.addAttribute(.paragraphStyle, value: neutral, range: range)
      }
      if text.string.hasSuffix("\n") {
        text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
      }
      result.append(text)
    }
    return result
  }

  /// A table's cells end each with a paragraph break: a tab between the cells of a row, a line
  /// break at its end.
  static func tabulated(_ text: NSAttributedString) -> String {
    let string = text.string as NSString
    var result = ""
    var start = 0
    while start < string.length {
      let rest = NSRange(location: start, length: string.length - start)
      let newline = string.range(of: "\n", range: rest)
      guard newline.location != NSNotFound else {
        result += string.substring(with: rest)
        break
      }
      // A cell's text as a whole: a character outside the BMP is two units.
      result += string.substring(
        with: NSRange(location: start, length: newline.location - start))
      // A passage that stops after a cell does not end with its separator — only that one: the
      // row's empty cells before it keep theirs.
      if newline.location < string.length - 1 {
        let style =
          text.attribute(.paragraphStyle, at: newline.location, effectiveRange: nil)
          as? NSParagraphStyle
        if let block = style?.textBlocks.last as? NSTextTableBlock,
          block.startingColumn + block.columnSpan < block.table.numberOfColumns
        {
          result += "\t"
        } else {
          result += "\n"
        }
      }
      start = newline.location + 1
    }
    return result
  }
}

extension EnvironmentValues {
  /// The selection of the message the views belong to, made by `MarkdownView`.
  @Entry var messageSelection: MessageSelection?
}
