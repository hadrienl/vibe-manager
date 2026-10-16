import AppKit
import SwiftUI

/// A place in the conversation's text: a block of the conversation, one of the segments its
/// message is drawn by, in reading order, and an offset in that segment's text.
struct SelectionPlace: Equatable {
  var block: String
  var segment: Int
  var offset: Int
}

/// A place, its block numbered in the conversation's order: what places are compared by.
struct SelectionKey: Comparable {
  var block: Int
  var segment: Int
  var offset: Int

  static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.block, lhs.segment, lhs.offset) < (rhs.block, rhs.segment, rhs.offset)
  }
}

/// One selection for the whole conversation (#189, #381).
///
/// A message is drawn by several text views — its prose, each code block, each table —, and the
/// conversation by many messages, in a lazy stack: a message scrolled far away no longer has its
/// views. The selection is therefore kept as two places in the text, where it started and where
/// it ends, rather than as the views' ranges: each view on screen is given the part it draws, a
/// view that comes back is given its part again, and a copy takes the text of the messages whose
/// views are gone from the conversation itself.
///
/// A message outside a conversation — a plan, a sub-agent's prompt — has a selection of its own,
/// its views all in one block.
@MainActor
final class ConversationSelection {
  /// What the conversation knows of its blocks, for those whose views are gone.
  struct Source {
    /// The blocks, in the conversation's order, selectable or not.
    var blocks: () -> [String]
    /// The text of a block's segments, in reading order, as its views would show it: none for a
    /// block that holds no selectable text.
    var pieces: (String) -> [SelectionText.Piece]
  }

  /// A segment on screen: its view, its block and its rank among the block's segments.
  struct Shown {
    let view: SegmentTextView
    let block: String
    let segment: Int
  }

  private struct Member {
    weak var view: SegmentTextView?
  }

  var source: Source?
  private var members: [Member] = []
  /// The events that follow a click, until the button is released: the window's; a test gives
  /// its own.
  static var nextEvent: (NSWindow) -> NSEvent? = {
    $0.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic])
  }
  /// Where the selection started — ⇧-click extends it from there — and where it ends.
  private(set) var anchor: SelectionPlace?
  private(set) var focus: SelectionPlace?
  /// While it sets its segments' ranges itself, rather than a segment on its own.
  private(set) var applying = false
  private var refreshScheduled = false

  func register(_ view: SegmentTextView) {
    members.removeAll { $0.view == nil }
    guard !members.contains(where: { $0.view === view }) else { return }
    members.append(Member(view: view))
    setNeedsRefresh()
  }

  func unregister(_ view: SegmentTextView) {
    members.removeAll { $0.view == nil || $0.view === view }
  }

  /// The segments on screen, in reading order: from the top, then from the leading edge. SwiftUI
  /// makes the views in any order, and a code block in a list item is read where it is drawn.
  /// The stack lays its messages out in the conversation's order, so the order on screen is also
  /// the blocks', and a message's segments are all on screen together.
  var shown: [Shown] {
    let views = members.compactMap(\.view).filter { $0.window != nil }
    let frames = views.map { $0.convert($0.bounds, to: nil) }
    let sorted = zip(views, frames).sorted { first, second in
      if abs(first.1.maxY - second.1.maxY) > 0.5 { return first.1.maxY > second.1.maxY }
      return first.1.minX < second.1.minX
    }.map(\.0)
    var counts: [String: Int] = [:]
    return sorted.map { view in
      let block = view.selectionBlock
      let segment = counts[block, default: 0]
      counts[block] = segment + 1
      return Shown(view: view, block: block, segment: segment)
    }
  }

  var segments: [SegmentTextView] { shown.map(\.view) }

  /// Whether its selection is the one the keyboard acts on: its window is key, and one of its
  /// segments holds the keyboard.
  var isActive: Bool {
    guard let window, window.isKeyWindow else { return false }
    return members.contains { $0.view != nil && $0.view === window.firstResponder }
  }

  var window: NSWindow? {
    members.lazy.compactMap(\.view?.window).first
  }

  var hasSelection: Bool {
    guard let anchor, let focus else { return false }
    return anchor != focus
  }

  // MARK: Selecting

  /// Follows a drag that started with `event` in `view`, until the button is released.
  func track(_ event: NSEvent, in view: SegmentTextView) {
    var shown = shown
    guard let window = view.window, shown.contains(where: { $0.view === view }),
      let start = Self.place(at: event.locationInWindow, in: shown)
    else { return }
    SelectionOwner.shared.claim(self)
    if !event.modifierFlags.contains(.shift) || anchor == nil { anchor = start }
    focus = start
    let clicked = view.clickedLink(at: event.locationInWindow)
    apply(shown)
    window.makeFirstResponder(view)
    // Kept from the start: the view clicked may leave the screen while the drag scrolls.
    let scrollViews = Array(
      sequence(first: view.enclosingScrollView) { $0?.enclosingScrollView }.lazy
        .prefix { $0 != nil }.compactMap { $0 })

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
          focus = anchor
          apply()
          view.clicked(onLink: clicked.link, at: clicked.index)
        }
        keepKeyboard(in: window)
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
      if moved {
        // The innermost scroll view — a code block's, sideways — then the conversation's.
        for scrollView in scrollViews { scrollView.contentView.autoscroll(with: last) }
      }
      // Messages come on screen, others leave, as the conversation scrolls.
      shown = self.shown
      if let place = Self.place(at: last.locationInWindow, in: shown) { focus = place }
      apply(shown)
    }
  }

  /// A double or triple click chose a word or a paragraph in `view`, or the keyboard moved its
  /// selection: the selection is that segment's alone.
  func selectedWithin(_ view: SegmentTextView) {
    SelectionOwner.shared.claim(self)
    guard let item = shown.first(where: { $0.view === view }) else { return }
    let range = view.selectedRange()
    anchor = SelectionPlace(block: item.block, segment: item.segment, offset: range.location)
    focus = SelectionPlace(block: item.block, segment: item.segment, offset: NSMaxRange(range))
    apply()
  }

  /// Selects the whole of the message `view` belongs to.
  func selectAll(in view: SegmentTextView) {
    let block = view.selectionBlock
    let lengths = pieces(of: block, shown: shown).map(\.text.length)
    guard let last = lengths.last else { return }
    SelectionOwner.shared.claim(self)
    anchor = SelectionPlace(block: block, segment: 0, offset: 0)
    focus = SelectionPlace(block: block, segment: lengths.count - 1, offset: last)
    apply()
  }

  func clear() {
    anchor = nil
    focus = nil
    apply()
  }

  /// Redrawn when it becomes, or stops being, the active selection: the segments without the
  /// keyboard draw it in the same colour as the one with it (`SegmentLayoutManager`).
  func redisplay() {
    for view in members.compactMap(\.view) where view.selectedRange().length > 0 {
      view.needsDisplay = true
    }
  }

  /// A segment came on screen, or its text changed: it is given its part once the views made
  /// with it are laid out.
  func setNeedsRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      refreshScheduled = false
      if anchor != nil { apply() }
    }
  }

  /// The segment with the keyboard left the screen, scrolled away: Copy still has to reach the
  /// selection, through a segment that is still there.
  func keyboardLeft() {
    // Not the window itself: one that is closing cannot be referenced, even weakly.
    DispatchQueue.main.async { [weak self] in
      guard let self, hasSelection, let next = shown.first?.view, let window = next.window,
        window.firstResponder === window || window.firstResponder == nil
      else { return }
      window.makeFirstResponder(next)
    }
  }

  private func keepKeyboard(in window: NSWindow) {
    guard let responder = window.firstResponder as? SegmentTextView, responder.window == nil
    else { return }
    if let next = shown.first?.view { window.makeFirstResponder(next) }
  }

  /// Gives each segment on screen the part of the selection it draws.
  func apply(_ shown: [Shown]? = nil) {
    let shown = shown ?? self.shown
    applying = true
    defer { applying = false }
    guard let anchor, let focus else {
      for item in shown where item.view.selectedRange().length > 0 {
        item.view.setSelectedRange(NSRange(location: item.view.selectedRange().location, length: 0))
      }
      return
    }
    let order = blockOrder(shown)
    let (low, high) = Self.ordered(key(anchor, order), key(focus, order))
    for item in shown {
      let range = Self.range(
        block: order[item.block] ?? Int.max, segment: item.segment,
        length: item.view.textLength, from: low, to: high)
      if item.view.selectedRange() != range { item.view.setSelectedRange(range) }
    }
  }

  // MARK: Copying

  /// The selected passage, segment by segment, in reading order — from the conversation itself
  /// for the messages no longer on screen.
  var selectedPieces: [SelectionText.Piece] {
    guard let anchor, let focus, anchor != focus else { return [] }
    let shown = shown
    let order = blockOrder(shown)
    let (low, high) = Self.ordered(key(anchor, order), key(focus, order))
    let blocks = order.filter { $0.value >= low.block && $0.value <= high.block }
      .sorted { $0.value < $1.value }
    return blocks.flatMap { block, index in
      pieces(of: block, shown: shown).enumerated().compactMap { segment, piece in
        let range = Self.range(
          block: index, segment: segment, length: piece.text.length, from: low, to: high)
        guard range.length > 0 else { return nil }
        return SelectionText.Piece(
          kind: piece.kind, text: piece.text.attributedSubstring(from: range))
      }
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

  /// A block's text: its views' when it is on screen, else the conversation's.
  private func pieces(of block: String, shown: [Shown]) -> [SelectionText.Piece] {
    let views = shown.filter { $0.block == block }.map(\.view)
    if views.isEmpty, let source { return source.pieces(block) }
    return views.compactMap { view in
      view.textStorage.map {
        SelectionText.Piece(kind: view.kind, text: NSAttributedString(attributedString: $0))
      }
    }
  }

  // MARK: Order

  /// The blocks numbered in the conversation's order; without a conversation, in the order on
  /// screen.
  private func blockOrder(_ shown: [Shown]) -> [String: Int] {
    var order: [String: Int] = [:]
    if let source {
      for (index, block) in source.blocks().enumerated() { order[block] = index }
    }
    for item in shown where order[item.block] == nil { order[item.block] = order.count }
    return order
  }

  private func key(_ place: SelectionPlace, _ order: [String: Int]) -> SelectionKey {
    SelectionKey(block: order[place.block] ?? Int.max, segment: place.segment, offset: place.offset)
  }

  private static func ordered(_ first: SelectionKey, _ second: SelectionKey)
    -> (SelectionKey, SelectionKey)
  {
    first <= second ? (first, second) : (second, first)
  }

  /// What a segment selects between two keys, `low` before `high`: everything when it lies
  /// between them, the two ends partly.
  static func range(
    block: Int, segment: Int, length: Int, from low: SelectionKey, to high: SelectionKey
  ) -> NSRange {
    let place = (block, segment)
    let isLow = place == (low.block, low.segment)
    let isHigh = place == (high.block, high.segment)
    let from = isLow ? min(low.offset, length) : 0
    let to = isHigh ? min(high.offset, length) : length
    guard place >= (low.block, low.segment), place <= (high.block, high.segment), to > from else {
      return NSRange(location: isLow ? from : 0, length: 0)
    }
    return NSRange(location: from, length: to - from)
  }

  // MARK: Geometry

  /// Where a point of the window falls among the segments on screen: in one of them, or, between
  /// two, at the start of the next — a rule, a margin, a code block's header, another message.
  static func place(at point: NSPoint, in shown: [Shown]) -> SelectionPlace? {
    guard !shown.isEmpty else { return nil }
    let frames = shown.map { $0.view.convert($0.view.bounds, to: nil) }
    let (index, offset): (Int, Int)
    switch hit(y: point.y, frames: frames) {
    case .start(let found):
      (index, offset) = (found, 0)
    case .end(let found):
      (index, offset) = (found, shown[found].view.textLength)
    case .inside(let found):
      let view = shown[found].view
      var local = view.convert(point, from: nil)
      // Within what shows of a code block scrolled sideways, not the whole of its longest line.
      let visible = view.visibleRect.isEmpty ? view.bounds : view.visibleRect
      local.x = min(max(local.x, visible.minX), visible.maxX)
      local.y = min(max(local.y, 0), view.bounds.height)
      (index, offset) = (found, view.characterIndexForInsertion(at: local))
    }
    return SelectionPlace(block: shown[index].block, segment: shown[index].segment, offset: offset)
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
}

/// Makes sure only one selection shows in a window: starting one clears the one before, in
/// another message or in this one. Another window keeps its own, as macOS does.
@MainActor
final class SelectionOwner {
  static let shared = SelectionOwner()

  private struct Owner {
    weak var window: NSWindow?
    weak var selection: ConversationSelection?
  }

  private var owners: [Owner] = []

  func claim(_ selection: ConversationSelection) {
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
  /// The selection the views belong to: the conversation's (`ConversationView`), or, outside
  /// one, the message's own (`MarkdownView`).
  @Entry var conversationSelection: ConversationSelection?
  /// The block of the conversation a message's views draw, for its selection; `nil` outside the
  /// conversation's prompts, answers and reasoning.
  @Entry var selectionBlock: String?
}
