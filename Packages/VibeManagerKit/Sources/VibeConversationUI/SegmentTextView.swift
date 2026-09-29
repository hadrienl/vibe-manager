import AppKit
import Observation
import SwiftUI
import VibeApplication

/// What a segment of a message holds, which decides how it is copied.
enum SegmentKind {
  case prose
  case code
  case table
}

/// A segment of a message — a run of prose, a code block's text, a table, what the user sent —,
/// selectable, and part of its message's selection.
struct SegmentView: NSViewRepresentable {
  enum Content: Equatable {
    case prose([MarkdownBlock], secondary: Bool)
    case code(String, language: String?)
    case table(header: [[InlineRun]], rows: [[[InlineRun]]])
    case plain(String, color: ThemeColor)

    var kind: SegmentKind {
      switch self {
      case .prose, .plain: .prose
      case .code: .code
      case .table: .table
      }
    }
  }

  let content: Content
  /// The whole message, for Copy Message and the Edit menu's Copy as Markdown.
  var markdown: String?
  /// As wide as its text when that is narrower than what it is offered: a bubble hugs its words.
  var hugsText = false
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @Environment(\.openURL) private var openURL
  @Environment(\.messageSelection) private var selection
  @Environment(\.conversationLinks) private var links

  struct Input: Equatable {
    var content: Content
    var theme: ConversationTheme
    var size: Double
    var spacing: Double
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var input: Input?
    var openURL: OpenURLAction?
    var links: ConversationLinks?

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else {
        return false
      }
      // Only what the parser let through is a link. The session's rule when there is one (#186),
      // else `openURL`, which is what SwiftUI's links used.
      guard MarkdownDocument.safeLink(url.absoluteString) != nil else { return true }
      if let links {
        links.click(url)
      } else {
        openURL?(url)
      }
      return true
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> SegmentTextView {
    let view = SegmentTextView()
    view.kind = content.kind
    view.delegate = context.coordinator
    return view
  }

  func updateNSView(_ view: SegmentTextView, context: Context) {
    context.coordinator.openURL = openURL
    context.coordinator.links = links
    view.links = links
    view.markdown = markdown
    if view.selection !== selection { view.selection = selection }
    let size = appearance.textSize.pointSize
    let input = Input(
      content: content, theme: theme, size: size,
      spacing: theme.layout.at(appearance.density).paragraphSpacing)
    // Rebuilt only when what it shows changed: rebuilding would drop the reader's selection.
    guard context.coordinator.input != input else { return }
    context.coordinator.input = input
    view.kind = content.kind
    view.quoteBarColor = theme.border.nsColor
    view.linkTextAttributes = [
      .foregroundColor: theme.accent.nsColor,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
      .cursor: NSCursor.pointingHand,
    ]
    view.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
    switch content {
    case .prose(let blocks, let secondary):
      view.show(
        MarkdownProse.attributedString(
          blocks, theme: theme, size: size, spacing: input.spacing, secondary: secondary))
    case .code(let code, let language):
      view.show(MarkdownProse.code(code, language: language, theme: theme, size: size * 0.88))
    case .table(let header, let rows):
      view.show(MarkdownProse.table(header: header, rows: rows, theme: theme, size: size * 0.92))
    case .plain(let text, let color):
      view.show(MarkdownProse.plain(text, theme: theme, size: size, color: color))
    }
  }

  static func dismantleNSView(_ view: SegmentTextView, coordinator: Coordinator) {
    view.selection = nil
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView view: SegmentTextView, context: Context)
    -> CGSize?
  {
    guard let proposed = proposal.width.flatMap({ $0.isFinite ? $0 : nil }) else {
      // Scrolled sideways: as wide as its longest line.
      let natural = view.naturalWidth
      return CGSize(width: natural, height: view.height(forWidth: max(natural, 1)))
    }
    let width = hugsText ? min(view.naturalWidth, proposed) : proposed
    return CGSize(width: width, height: view.height(forWidth: max(width, 1)))
  }
}

/// A text view that reads and selects, never edits, sized by SwiftUI rather than by a scroll view.
///
/// Its message's selection (`MessageSelection`) follows a click and a drag across the message's
/// segments; a double or triple click, the keyboard and the menus stay the text view's own.
final class SegmentTextView: NSTextView {
  nonisolated static let quoteBarWidth: CGFloat = 3

  var kind = SegmentKind.prose
  /// The message's Markdown, for Copy Message and Copy as Markdown.
  var markdown: String? {
    didSet { if FocusedMarkdown.shared.holder == ObjectIdentifier(self) { claimFocus() } }
  }
  var quoteBarColor = NSColor.separatorColor
  /// The session's rule for the menu of a link (#186).
  var links: ConversationLinks?
  /// Where Copy writes; a test gives its own, and leaves the user's clipboard alone.
  var pasteboard = NSPasteboard.general

  weak var selection: MessageSelection? {
    didSet {
      guard oldValue !== selection else { return }
      oldValue?.unregister(self)
      selection?.register(self)
    }
  }

  var textLength: Int { textStorage?.length ?? 0 }

  convenience init() {
    // TextKit 1: the quotes' bars are drawn from its layout manager, tables are its text blocks.
    let storage = NSTextStorage()
    let layout = SegmentLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(
      size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    container.widthTracksTextView = false
    layout.addTextContainer(container)
    self.init(frame: .zero, textContainer: container)
    isEditable = false
    isSelectable = true
    isRichText = true
    drawsBackground = false
    textContainerInset = .zero
    isVerticallyResizable = false
    isHorizontallyResizable = false
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setAccessibilityRole(.staticText)
  }

  /// The sizes measured for the text shown, by width: SwiftUI asks for the same ones again.
  private var measured: [CGFloat: CGSize] = [:]

  func show(_ text: NSAttributedString) {
    textStorage?.setAttributedString(text)
    measured.removeAll()
  }

  func height(forWidth width: CGFloat) -> CGFloat {
    size(forWidth: width).height
  }

  /// The width the text takes when nothing wraps it: a line of a code block may be very long.
  var naturalWidth: CGFloat {
    size(forWidth: 1_000_000).width
  }

  /// Measured apart from the view's own layout, which a text view resizes as it pleases.
  private func size(forWidth width: CGFloat) -> CGSize {
    if let size = measured[width] { return size }
    let storage = NSTextStorage(attributedString: attributedString())
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(
      size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    layout.ensureLayout(for: container)
    let used = layout.usedRect(for: container)
    let size = CGSize(width: ceil(used.width), height: ceil(used.height))
    measured[width] = size
    return size
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    if newSize.width > 0, let container = textContainer, container.size.width != newSize.width {
      container.size = CGSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let storage = textStorage, let layout = layoutManager, let container = textContainer
    else { return }
    quoteBarColor.setFill()
    storage.enumerateAttribute(
      .quoteBars, in: NSRange(location: 0, length: storage.length)
    ) { value, range, _ in
      guard let bars = value as? [CGFloat] else { return }
      let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      var extent = CGRect.null
      layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
        extent = extent.union(used)
      }
      let top = extent.minY
      let bottom = min(extent.maxY, layout.usedRect(for: container).maxY)
      guard !extent.isNull, bottom > top else { return }
      for x in bars {
        let bar = CGRect(
          x: x + textContainerOrigin.x, y: top + textContainerOrigin.y,
          width: Self.quoteBarWidth, height: bottom - top)
        if bar.intersects(dirtyRect) {
          NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
      }
    }
  }

  // MARK: Selecting

  override func mouseDown(with event: NSEvent) {
    guard let selection, !event.modifierFlags.contains(.control) else {
      return super.mouseDown(with: event)
    }
    if event.clickCount > 1 {
      // A word, a paragraph: the text view's own, in this segment only.
      super.mouseDown(with: event)
      selection.selectedWithin(self)
      return
    }
    selection.track(event, in: self)
  }

  /// The link under a point of the window, if the point is on its text, for a click to open it.
  func clickedLink(at point: NSPoint) -> (link: Any, index: Int)? {
    guard let layout = layoutManager, let container = textContainer, let storage = textStorage
    else { return nil }
    var local = convert(point, from: nil)
    local.x -= textContainerOrigin.x
    local.y -= textContainerOrigin.y
    let glyph = layout.glyphIndex(for: local, in: container)
    guard glyph < layout.numberOfGlyphs,
      layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        .contains(local)
    else { return nil }
    let index = layout.characterIndexForGlyph(at: glyph)
    guard index < storage.length,
      let link = storage.attribute(.link, at: index, effectiveRange: nil)
    else { return nil }
    return (link, index)
  }

  override func setSelectedRanges(
    _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
  ) {
    super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    // Moved by the keyboard — an arrow, ⇧-arrow —, the selection is this segment's alone now.
    if let selection, !selection.applying, !stillSelecting, window?.firstResponder === self {
      selection.selectedWithin(self)
    }
  }

  override func selectAll(_ sender: Any?) {
    guard let selection else { return super.selectAll(sender) }
    selection.selectAll()
    window?.makeFirstResponder(self)
  }

  override func copy(_ sender: Any?) {
    guard let selection else { return super.copy(sender) }
    selection.copy(to: pasteboard)
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    // Copy is the message's: its focused segment may hold none of the selection.
    if item.action == #selector(copy(_:)), let selection { return selection.hasSelection }
    return super.validateUserInterfaceItem(item)
  }

  // MARK: Focus

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became {
      claimFocus()
      selection?.redisplay()
    }
    return became
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned {
      FocusedMarkdown.shared.release(ObjectIdentifier(self))
      selection?.redisplay()
    }
    return resigned
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    NotificationCenter.default.removeObserver(
      self, name: NSWindow.didBecomeKeyNotification, object: nil)
    NotificationCenter.default.removeObserver(
      self, name: NSWindow.didResignKeyNotification, object: nil)
    guard let newWindow else { return }
    // The segments without the keyboard turn grey, or back, with the window.
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(keyWindowChanged), name: name, object: newWindow)
    }
  }

  @objc private func keyWindowChanged() {
    if selectedRange().length > 0 { needsDisplay = true }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { FocusedMarkdown.shared.release(ObjectIdentifier(self)) }
  }

  private func claimFocus() {
    FocusedMarkdown.shared.hold(markdown, by: ObjectIdentifier(self))
  }

  // MARK: Menu

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event) ?? NSMenu()
    if let url = link(at: convert(event.locationInWindow, from: nil)) {
      // A link's actions, the same everywhere (#186), in place of the text view's own.
      for item in menu.items where LinkMenuItems.isTextViewLinkItem(item) {
        menu.removeItem(item)
      }
      let items = LinkMenuItems.items(for: url, links: links)
      for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
      if menu.items.count > items.count { menu.insertItem(.separator(), at: items.count) }
    }
    guard let markdown else { return menu }
    let item = NSMenuItem(
      title: String(localized: "Copy Message", bundle: .module),
      action: #selector(copyMessage(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = markdown
    let copyIndex = menu.items.firstIndex { $0.action == #selector(copy(_:)) }
    menu.insertItem(item, at: copyIndex.map { $0 + 1 } ?? 0)
    return menu
  }

  /// The link under a point of the view, if the parser let it through.
  func link(at point: NSPoint) -> URL? {
    guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else {
      return nil
    }
    let inContainer = NSPoint(
      x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
    let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
    let rect = layoutManager.boundingRect(
      forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
    guard rect.contains(inContainer) else { return nil }
    let index = layoutManager.characterIndexForGlyph(at: glyph)
    guard index < textStorage.length else { return nil }
    let value = textStorage.attribute(.link, at: index, effectiveRange: nil)
    let url = value as? URL ?? (value as? String).flatMap(URL.init(string:))
    return url.flatMap { MarkdownDocument.safeLink($0.absoluteString) }
  }

  @objc private func copyMessage(_ sender: NSMenuItem) {
    guard let markdown = sender.representedObject as? String else { return }
    pasteboard.clearContents()
    pasteboard.setString(markdown, forType: .string)
  }
}

/// Draws the selection of the segments without the keyboard in the active colour while their
/// message's selection is the active one: to the reader, a message is one text.
final class SegmentLayoutManager: NSLayoutManager {
  private static let inactive: [NSColor] = [
    .unemphasizedSelectedTextBackgroundColor, .unemphasizedSelectedContentBackgroundColor,
  ]

  override func fillBackgroundRectArray(
    _ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange,
    color: NSColor
  ) {
    var color = color
    let view = firstTextView as? SegmentTextView
    if Self.inactive.contains(color),
      MainActor.assumeIsolated({ view?.selection?.isActive == true })
    {
      // `color` only says what is set: the fill colour is the context's.
      color = .selectedTextBackgroundColor
      color.setFill()
    }
    super.fillBackgroundRectArray(
      rectArray, count: rectCount, forCharacterRange: charRange, color: color)
  }
}

/// The message whose text holds the keyboard — clicked into, or selected — for the Edit menu's
/// Copy as Markdown: a menu command reaches no view, so the view says what it would copy.
@MainActor
@Observable
public final class FocusedMarkdown {
  public static let shared = FocusedMarkdown()

  /// The Markdown of the message in focus, `nil` when no message text has the keyboard.
  public private(set) var markdown: String?
  @ObservationIgnored fileprivate var holder: ObjectIdentifier?

  public func copy() {
    guard let markdown else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(markdown, forType: .string)
  }

  func hold(_ markdown: String?, by view: ObjectIdentifier) {
    holder = view
    if self.markdown != markdown { self.markdown = markdown }
  }

  func release(_ view: ObjectIdentifier) {
    guard holder == view else { return }
    holder = nil
    markdown = nil
  }
}
