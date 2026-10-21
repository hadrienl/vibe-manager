import AppKit
import SwiftUI
import Testing
import VibeApplication

@testable import VibeConversationUI

@Suite("The conversation's selection, from one segment and one message to the next (#189, #381)")
@MainActor
struct ConversationSelectionTests {
  // MARK: Ranges and geometry

  @Test("Everything between two places is selected, the two ends partly, across messages")
  func ranges() {
    func ranges(from low: SelectionKey, to high: SelectionKey) -> [NSRange] {
      // Two messages: two segments, then one.
      [(0, 0, 10), (0, 1, 20), (1, 0, 8)].map { block, segment, length in
        ConversationSelection.range(
          block: block, segment: segment, length: length, from: low, to: high)
      }
    }
    #expect(
      ranges(
        from: SelectionKey(block: 0, segment: 0, offset: 4),
        to: SelectionKey(block: 1, segment: 0, offset: 3))
        == [
          NSRange(location: 4, length: 6), NSRange(location: 0, length: 20),
          NSRange(location: 0, length: 3),
        ])
    let within = ranges(
      from: SelectionKey(block: 0, segment: 1, offset: 2),
      to: SelectionKey(block: 0, segment: 1, offset: 12))
    #expect(
      within == [
        NSRange(location: 0, length: 0), NSRange(location: 2, length: 10),
        NSRange(location: 0, length: 0),
      ])
    let caret = ranges(
      from: SelectionKey(block: 1, segment: 0, offset: 5),
      to: SelectionKey(block: 1, segment: 0, offset: 5))
    #expect(caret[2] == NSRange(location: 5, length: 0))
  }

  @Test("Between two segments — a rule, a margin, a code block's header — is the next one's start")
  func hit() {
    // The window's y goes up: the first segment is the highest.
    let frames = [
      CGRect(x: 0, y: 300, width: 100, height: 50), CGRect(x: 0, y: 200, width: 100, height: 60),
    ]
    #expect(ConversationSelection.hit(y: 400, frames: frames) == .start(0))
    #expect(ConversationSelection.hit(y: 320, frames: frames) == .inside(0))
    #expect(ConversationSelection.hit(y: 280, frames: frames) == .start(1))
    #expect(ConversationSelection.hit(y: 230, frames: frames) == .inside(1))
    #expect(ConversationSelection.hit(y: 100, frames: frames) == .end(1))
  }

  // MARK: What is copied

  @Test("Code is copied as it is, a table as tab-separated lines, a blank line between them")
  func plainText() {
    let theme = ConversationTheme.systemDark
    let table = MarkdownProse.table(
      header: [[InlineRun(text: "Name")], [InlineRun(text: "Size")]],
      rows: [[[InlineRun(text: "a.txt")], [InlineRun(text: "12 KB")]]], theme: theme, size: 13)
    let pieces = [
      SelectionText.Piece(kind: .prose, text: NSAttributedString(string: "Before.")),
      SelectionText.Piece(
        kind: .code,
        text: MarkdownProse.code(
          "if a {\n    b()\n}", language: "swift", theme: theme, size: 12)),
      SelectionText.Piece(kind: .table, text: table),
      SelectionText.Piece(kind: .prose, text: NSAttributedString(string: "After.")),
    ]
    #expect(
      SelectionText.plain(pieces)
        == "Before.\n\nif a {\n    b()\n}\n\nName\tSize\na.txt\t12 KB\n\nAfter.")
  }

  @Test("Rich text keeps the fonts and the table, not the theme's colours")
  func richText() throws {
    let theme = ConversationTheme.systemDark
    let pieces = [
      SelectionText.Piece(
        kind: .code,
        text: MarkdownProse.code("let a = 1", language: "swift", theme: theme, size: 12)),
      SelectionText.Piece(
        kind: .table,
        text: MarkdownProse.table(
          header: [[InlineRun(text: "Name")]], rows: [[[InlineRun(text: "a")]]], theme: theme,
          size: 13)),
    ]
    let rich = SelectionText.rich(pieces)
    let whole = NSRange(location: 0, length: rich.length)
    var colours = 0
    rich.enumerateAttribute(.foregroundColor, in: whole) { value, _, _ in
      if value != nil { colours += 1 }
    }
    #expect(colours == 0)
    let font = try #require(rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(font.isFixedPitch)
    let header = (rich.string as NSString).range(of: "Name")
    let style = try #require(
      rich.attribute(.paragraphStyle, at: header.location, effectiveRange: nil) as? NSParagraphStyle
    )
    let block = try #require(style.textBlocks.first as? NSTextTableBlock)
    #expect(block.backgroundColor == nil)
    #expect(rich.rtf(from: whole, documentAttributes: [:]) != nil)
  }

  @Test("A table is as wide as its columns, a long cell wrapping at 320 points")
  func tableWidth() {
    let view = SegmentTextView()
    view.show(
      MarkdownProse.table(
        header: [[InlineRun(text: "Name")], [InlineRun(text: "Size")]],
        rows: [[[InlineRun(text: "a.txt")], [InlineRun(text: "12 KB")]]], theme: .systemLight,
        size: 13))
    #expect(view.naturalWidth > 40)
    #expect(view.naturalWidth < 200)
    view.show(
      MarkdownProse.table(
        header: [[InlineRun(text: String(repeating: "word ", count: 200))]], rows: [],
        theme: .systemLight, size: 13))
    #expect(view.naturalWidth <= 320 + 2 * 10 + 2)
    #expect(view.height(forWidth: 10_000) > 100)
  }

  // MARK: Gestures

  @Test("A drag from a paragraph to another selects the code and the table between, once")
  func dragAcross() throws {
    let harness = Harness()
    let message = harness.messages[0]
    harness.drag(
      from: (message.first, NSPoint(x: 30, y: 8)), to: (message.last, NSPoint(x: 40, y: 8)))
    #expect(message.segments.allSatisfy { $0.selectedRange().length > 0 })
    #expect(message.code.selectedRange() == NSRange(location: 0, length: message.code.textLength))
    let pasteboard = harness.pasteboard
    #expect(message.selection.copy(to: pasteboard))
    let copied = try #require(pasteboard.string(forType: .string))
    #expect(copied.contains("if ok {\n    run()\n}"))
    #expect(copied.contains("Name\tSize\na.txt\t12 KB"))
    #expect(!copied.hasPrefix("First"))
    #expect(copied.contains("paragraph of the message.\n\nlink\n\n"))
    #expect(pasteboard.data(forType: .rtf) != nil)
  }

  @Test("Starting a selection elsewhere clears the one before, in another message too")
  func oneSelection() {
    let harness = Harness()
    let (first, second) = (harness.messages[0], harness.messages[1])
    harness.drag(from: (first.first, NSPoint(x: 5, y: 8)), to: (first.code, NSPoint(x: 20, y: 5)))
    #expect(first.selection.hasSelection)
    harness.drag(
      from: (second.first, NSPoint(x: 5, y: 8)), to: (second.first, NSPoint(x: 60, y: 8)))
    #expect(!first.selection.hasSelection)
    #expect(second.first.selectedRange().length > 0)
    harness.drag(from: (second.last, NSPoint(x: 5, y: 8)), to: (second.last, NSPoint(x: 60, y: 8)))
    #expect(second.first.selectedRange().length == 0)
  }

  @Test("A word chosen by a double click in code is all that stays selected")
  func doubleClick() {
    let harness = Harness()
    let message = harness.messages[0]
    harness.drag(
      from: (message.first, NSPoint(x: 5, y: 8)), to: (message.last, NSPoint(x: 5, y: 8)))
    // The double click itself is the text view's own tracking, which reads `NSApp`'s queue.
    message.code.setSelectedRange(NSRange(location: 0, length: 2))
    message.selection.selectedWithin(message.code)
    #expect(message.segments.filter { $0.selectedRange().length > 0 } == [message.code])
    harness.click(message.last, at: NSPoint(x: 5, y: 8), flags: .shift)
    #expect(message.code.selectedRange().location == 0)
    #expect(message.last.selectedRange().length > 0)
  }

  @Test("⇧-click extends the selection from where it started, across segments")
  func shiftClick() {
    let harness = Harness()
    let message = harness.messages[0]
    harness.click(message.first, at: NSPoint(x: 30, y: 8))
    harness.click(message.last, at: NSPoint(x: 40, y: 8), flags: .shift)
    #expect(message.segments.allSatisfy { $0.selectedRange().length > 0 })
  }

  @Test("An arrow key collapses the selection to the segment that has the keyboard")
  func keyboard() {
    let harness = Harness()
    let message = harness.messages[0]
    harness.drag(
      from: (message.first, NSPoint(x: 30, y: 8)), to: (message.last, NSPoint(x: 40, y: 8)))
    #expect(harness.window.firstResponder === message.first)
    message.first.moveRight(nil)
    #expect(!message.selection.hasSelection)
  }

  @Test("A passage that stops after a table's cell does not end with a tab")
  func tableEnd() {
    let table = MarkdownProse.table(
      header: [[InlineRun(text: "Name")], [InlineRun(text: "Size")]], rows: [],
      theme: .systemLight, size: 13)
    let first = table.attributedSubstring(from: NSRange(location: 0, length: 5))
    #expect(SelectionText.plain([SelectionText.Piece(kind: .table, text: first)]) == "Name")
  }

  @Test("A table's emoji and empty cells survive the copy")
  func tableCharacters() {
    let table = MarkdownProse.table(
      header: [[InlineRun(text: "🚀 done")], [InlineRun(text: "b")], [], []], rows: [],
      theme: .systemLight, size: 13)
    #expect(
      SelectionText.plain([SelectionText.Piece(kind: .table, text: table)]) == "🚀 done\tb\t\t")
  }

  @Test("New text in a segment — a streamed token — leaves the rest of the selection alone")
  func streaming() {
    let harness = Harness()
    let message = harness.messages[0]
    harness.drag(
      from: (message.last, NSPoint(x: 40, y: 8)), to: (message.code, NSPoint(x: 20, y: 5)))
    #expect(harness.window.firstResponder === message.last)
    message.last.show(NSAttributedString(string: "Last paragraph, and more."))
    #expect(message.code.selectedRange().length > 0)
  }

  @Test("Another window keeps its selection")
  func windows() {
    let first = Harness()
    let second = Harness()
    first.drag(
      from: (first.messages[0].first, NSPoint(x: 5, y: 8)),
      to: (first.messages[0].code, NSPoint(x: 20, y: 5)))
    second.drag(
      from: (second.messages[0].first, NSPoint(x: 5, y: 8)),
      to: (second.messages[0].first, NSPoint(x: 60, y: 8)))
    #expect(first.messages[0].selection.hasSelection)
    #expect(second.messages[0].selection.hasSelection)
  }

  @Test("A click on a link opens it; a drag that starts on it only selects")
  func links() {
    let harness = Harness()
    let message = harness.messages[0]
    let delegate = LinkRecorder()
    message.link.delegate = delegate
    harness.click(message.link, at: NSPoint(x: 3, y: 8))
    #expect(delegate.links == ["https://example.com"])
    harness.drag(
      from: (message.link, NSPoint(x: 3, y: 8)), to: (message.last, NSPoint(x: 30, y: 8)))
    #expect(delegate.links.count == 1)
    #expect(message.link.selectedRange().length > 0)
  }

  @Test("⌘A selects the whole message, and Copy follows the message rather than its segment")
  func selectAllAndCopy() {
    let harness = Harness()
    let message = harness.messages[0]
    message.code.selectAll(nil)
    #expect(message.segments.allSatisfy { $0.selectedRange().length == $0.textLength })
    #expect(!harness.messages[1].selection.hasSelection)
    // A selection that starts at the very end of a segment leaves it empty; Copy stays enabled.
    let end = message.first.textLength
    harness.drag(
      from: (message.first, NSPoint(x: 390, y: 8)), to: (message.code, NSPoint(x: 20, y: 5)))
    #expect(message.first.selectedRange() == NSRange(location: end, length: 0))
    let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    #expect(message.first.validateUserInterfaceItem(copy))
    harness.messages[1].first.selectAll(nil)
    #expect(!message.first.validateUserInterfaceItem(copy))
  }

  @Test("The segments without the keyboard draw the selection as the one with it does")
  func activeColour() throws {
    let harness = Harness()
    let message = harness.messages[0]
    message.blank.selectAll(nil)
    #expect(harness.window.firstResponder === message.blank)
    harness.window.key = true
    let focused = try harness.colour(of: message.blank)
    let other = try harness.colour(of: message.spaces)
    #expect(focused == other)
    harness.window.key = false
    let inactive = try harness.colour(of: message.spaces)
    #expect(inactive != other)
  }

  // MARK: From one message to the next (#381)

  @Test("A drag from one message to the next selects both, and copies them in order")
  func dragAcrossMessages() throws {
    let harness = Harness(shared: true)
    let (first, second) = (harness.messages[0], harness.messages[1])
    harness.drag(from: (first.code, NSPoint(x: 5, y: 5)), to: (second.code, NSPoint(x: 20, y: 5)))
    #expect(first.first.selectedRange().length == 0)
    #expect(NSMaxRange(first.code.selectedRange()) == first.code.textLength)
    #expect(first.last.selectedRange().length == first.last.textLength)
    #expect(second.first.selectedRange().length == second.first.textLength)
    #expect(second.code.selectedRange().length > 0)
    #expect(second.last.selectedRange().length == 0)
    #expect(first.selection.copy(to: harness.pasteboard))
    let copied = try #require(harness.pasteboard.string(forType: .string))
    #expect(copied.contains("Name\tSize\na.txt\t12 KB\n\nLast paragraph.\n\nFirst of message 1."))
    // Starting again in the first message clears the second's part.
    harness.drag(from: (first.first, NSPoint(x: 5, y: 8)), to: (first.first, NSPoint(x: 60, y: 8)))
    #expect(second.code.selectedRange().length == 0)
  }

  @Test("A message scrolled away is copied from the conversation, whole")
  func copyWithoutViews() throws {
    let harness = Harness(messages: 3, shared: true)
    let (first, middle, last) = (harness.messages[0], harness.messages[1], harness.messages[2])
    harness.drag(from: (first.last, NSPoint(x: 5, y: 8)), to: (last.first, NSPoint(x: 60, y: 8)))
    #expect(middle.code.selectedRange().length == middle.code.textLength)
    // The lazy stack lets the middle message go.
    for view in middle.segments { view.removeFromSuperview() }
    #expect(first.selection.segments.count == 14)
    #expect(first.selection.copy(to: harness.pasteboard))
    let copied = try #require(harness.pasteboard.string(forType: .string))
    #expect(copied.hasPrefix("ast paragraph.\n\nFirst of message 1.\n\nlink"))
    #expect(
      copied.contains(
        "if ok {\n    run()\n}\n\nName\tSize\na.txt\t12 KB\n\nLast paragraph.\n\nFirst"))
  }

  @Test("A segment made again, scrolled back on screen, takes back its part of the selection")
  func segmentMadeAgain() async throws {
    let harness = Harness(shared: true)
    let (first, second) = (harness.messages[0], harness.messages[1])
    harness.drag(from: (first.code, NSPoint(x: 5, y: 5)), to: (second.last, NSPoint(x: 40, y: 8)))
    let old = second.code
    let frame = old.frame
    let superview = try #require(old.superview)
    old.removeFromSuperview()
    old.selection = nil
    let again = SegmentTextView()
    again.kind = .code
    again.show(NSAttributedString(attributedString: try #require(old.textStorage)))
    again.frame = frame
    again.selectionBlock = "m1"
    again.selection = first.selection
    superview.addSubview(again)
    #expect(again.selectedRange().length == 0)
    for _ in 0..<50 where again.selectedRange().length == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(again.selectedRange() == NSRange(location: 0, length: again.textLength))
    #expect(second.last.selectedRange().length > 0)
  }

  @Test(
    "Paragraph, code and table of answers drawn by SwiftUI are one selection, message to message")
  func swiftUI() throws {
    let harness = Harness(messages: 0)
    let selection = ConversationSelection()
    let first =
      "First paragraph.\n\n```swift\nlet a = 1\n```\n\n| Name | Size |\n| --- | --- |\n| a.txt | 12 KB |\n\nAfter the table."
    let second = "- one\n- two\n\n> quoted\n\nLast."
    harness.window.contentView = NSHostingView(
      rootView: VStack(alignment: .leading, spacing: 20) {
        AgentTextView(text: first).environment(\.selectionBlock, "a")
        AgentTextView(text: second).environment(\.selectionBlock, "b")
        // Outside the conversation's prompts and answers: a selection of its own.
        MarkdownView(text: "A plan.")
      }
      .environment(\.conversationSelection, selection)
      .frame(width: 400, height: 800, alignment: .top))
    harness.window.layoutIfNeeded()
    let shown = selection.shown
    #expect(shown.map(\.block) == ["a", "a", "a", "a", "b"])
    #expect(shown.map(\.view.kind) == [.prose, .code, .table, .prose, .prose])
    // What a copy reads of a message scrolled away is what its views show.
    let theme = ConversationTheme.systemLight
    for (block, text) in [("a", first), ("b", second)] {
      let model = MarkdownBlocksView.contents(MarkdownCache.shared.blocks(for: text)).map {
        SegmentView.text(of: $0, theme: theme, size: 14, spacing: 8).string
      }
      #expect(model == shown.filter { $0.block == block }.map { $0.view.string })
    }
    let views = shown.map(\.view)
    harness.drag(from: (views[0], NSPoint(x: 2, y: 4)), to: (views[4], NSPoint(x: 10, y: 4)))
    #expect(views[0..<4].allSatisfy { $0.selectedRange().length == $0.textLength })
    #expect(views[4].selectedRange().length > 0)
    #expect(!selection.segments.contains { $0.string == "A plan." })
  }
}

/// Two messages, each a paragraph with a link, one of blanks, a code block, a table and a last
/// paragraph, stacked in a window that is never shown.
@MainActor
private final class Harness {
  final class Window: NSWindow {
    var key = false
    override var isKeyWindow: Bool { key }
  }

  final class Flipped: NSView {
    override var isFlipped: Bool { true }
  }

  struct Message {
    let selection: ConversationSelection
    let segments: [SegmentTextView]
    var first: SegmentTextView { segments[0] }
    var link: SegmentTextView { segments[1] }
    var blank: SegmentTextView { segments[2] }
    var spaces: SegmentTextView { segments[3] }
    var code: SegmentTextView { segments[4] }
    var last: SegmentTextView { segments[6] }
  }

  let window = Window(
    contentRect: NSRect(x: 0, y: 0, width: 420, height: 900), styleMask: [.titled],
    backing: .buffered, defer: false)
  let pasteboard = NSPasteboard(name: NSPasteboard.Name("vibe.tests.\(UUID().uuidString)"))
  var messages: [Message] = []
  /// The events that follow a click. Not `NSApp`'s queue: taking events from it outside
  /// `NSApp.run` ends the test process, silently.
  private var queue: [NSEvent] = []

  /// `shared`: one selection for all the messages, as in a conversation, which knows their text.
  init(messages count: Int = 2, shared: Bool = false) {
    _ = NSApplication.shared
    let height = CGFloat(max(count, 2)) * 450
    window.setContentSize(NSSize(width: 420, height: height))
    let content = Flipped(frame: NSRect(x: 0, y: 0, width: 420, height: height))
    window.contentView = content
    let conversation = ConversationSelection()
    var texts: [String: [SelectionText.Piece]] = [:]
    if shared {
      conversation.source = ConversationSelection.Source(
        blocks: { (0..<count).map { "m\($0)" } }, pieces: { texts[$0] ?? [] })
    }
    let theme = ConversationTheme.systemLight
    let font = NSFont.systemFont(ofSize: 14)
    func prose(_ text: String) -> NSAttributedString {
      NSAttributedString(string: text, attributes: [.font: font])
    }
    var y: CGFloat = 10
    for index in 0..<count {
      let selection = shared ? conversation : ConversationSelection()
      let block = shared ? "m\(index)" : ""
      let pieces: [(NSAttributedString, SegmentKind)] = [
        (
          prose(index == 0 ? "First paragraph of the message." : "First of message \(index)."),
          .prose
        ),
        (
          NSAttributedString(
            string: "link", attributes: [.font: font, .link: URL(string: "https://example.com")!]),
          .prose
        ),
        (prose("          "), .prose),
        (prose("                                        "), .prose),
        (
          MarkdownProse.code(
            "if ok {\n    run()\n}", language: "swift", theme: theme, size: 12), .code
        ),
        (
          MarkdownProse.table(
            header: [[InlineRun(text: "Name")], [InlineRun(text: "Size")]],
            rows: [[[InlineRun(text: "a.txt")], [InlineRun(text: "12 KB")]]], theme: theme,
            size: 13), .table
        ),
        (prose("Last paragraph."), .prose),
      ]
      var segments: [SegmentTextView] = []
      texts[block] = pieces.map { SelectionText.Piece(kind: $0.1, text: $0.0) }
      for (text, kind) in pieces {
        let view = SegmentTextView()
        view.kind = kind
        view.show(text)
        view.pasteboard = pasteboard
        let height = view.height(forWidth: 400)
        view.frame = NSRect(x: 10, y: y, width: 400, height: height)
        content.addSubview(view)
        view.selectionBlock = block
        view.selection = selection
        segments.append(view)
        y += height + 12
      }
      y += 30
      messages.append(Message(selection: selection, segments: segments))
    }
  }

  deinit {
    MainActor.assumeIsolated {
      pasteboard.releaseGlobally()
      ConversationSelection.nextEvent = {
        $0.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
      }
    }
  }

  func click(
    _ view: SegmentTextView, at point: NSPoint, count: Int = 1, flags: NSEvent.ModifierFlags = []
  ) {
    let location = view.convert(point, to: nil)
    queue = [event(.leftMouseUp, at: location, count: count, flags: flags)]
    down(on: view, at: location, count: count, flags: flags)
  }

  func drag(from start: (SegmentTextView, NSPoint), to end: (SegmentTextView, NSPoint)) {
    let from = start.0.convert(start.1, to: nil)
    let to = end.0.convert(end.1, to: nil)
    let middle = NSPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
    queue = [
      event(.leftMouseDragged, at: middle), event(.leftMouseDragged, at: to),
      event(.leftMouseUp, at: to),
    ]
    down(on: start.0, at: from)
  }

  /// Delivered as the window would: to the view found under the point.
  private func down(
    on view: SegmentTextView, at location: NSPoint, count: Int = 1,
    flags: NSEvent.ModifierFlags = []
  ) {
    ConversationSelection.nextEvent = { [unowned self] _ in
      queue.isEmpty ? nil : queue.removeFirst()
    }
    let hit = window.contentView?.superview?.hitTest(location)
    #expect(hit === view)
    hit?.mouseDown(with: event(.leftMouseDown, at: location, count: count, flags: flags))
  }

  private func event(
    _ type: NSEvent.EventType, at location: NSPoint, count: Int = 1,
    flags: NSEvent.ModifierFlags = []
  ) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: location, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
  }

  /// The colour a segment paints its selection with, among its blanks.
  func colour(of view: SegmentTextView) throws -> NSColor {
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let colour = try #require(bitmap.colorAt(x: 3, y: Int(view.bounds.midY)))
    return try #require(colour.usingColorSpace(.sRGB))
  }
}

private final class LinkRecorder: NSObject, NSTextViewDelegate {
  var links: [String] = []

  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    links.append("\(link)")
    return true
  }
}
