import AppKit
import SwiftUI
import VibeApplication

/// A run of a message's prose — headings, paragraphs, lists and quotes that follow one another —
/// drawn as one attributed string, so that one text view holds it and a selection runs from one
/// paragraph to the next. SwiftUI cannot select across two `Text`s on macOS 14.
///
/// Code blocks, tables and rules are not prose: they keep their own views, their Copy button and
/// their horizontal scrolling.
enum MarkdownProse {
  /// A message cut into what one text view can draw and what needs a view of its own.
  enum Segment: Hashable {
    case prose([MarkdownBlock])
    case block(MarkdownBlock)
  }

  static func isProse(_ block: MarkdownBlock) -> Bool {
    switch block {
    case .heading, .paragraph: return true
    case .list(_, _, let items): return items.allSatisfy { $0.blocks.allSatisfy(isProse) }
    case .quote(let blocks): return blocks.allSatisfy(isProse)
    case .code, .table, .rule: return false
    }
  }

  static func segments(_ blocks: [MarkdownBlock]) -> [Segment] {
    var result: [Segment] = []
    var prose: [MarkdownBlock] = []
    for block in blocks {
      if isProse(block) {
        prose.append(block)
      } else {
        if !prose.isEmpty { result.append(.prose(prose)) }
        prose = []
        result.append(.block(block))
      }
    }
    if !prose.isEmpty { result.append(.prose(prose)) }
    return result
  }

  /// What the text view draws: one paragraph per line of the string, spaced as the SwiftUI views
  /// spaced their blocks.
  static func attributedString(
    _ blocks: [MarkdownBlock], theme: ConversationTheme, size: Double, spacing: Double,
    secondary: Bool = false
  ) -> NSAttributedString {
    var builder = Builder(theme: theme, size: size)
    builder.append(
      blocks,
      context: Builder.Context(
        color: (secondary ? theme.secondaryText : theme.text).nsColor, quotes: []),
      spacing: spacing)
    return builder.result()
  }

  private struct Builder {
    struct Context {
      var indent: CGFloat = 0
      var color: NSColor
      /// Where the bars of the quotes the text is in are drawn.
      var quotes: [CGFloat]
      /// The marker of the list item whose first paragraph comes next, and where it starts.
      var marker: NSAttributedString?
      var markerIndent: CGFloat = 0
    }

    struct Paragraph {
      var text: NSMutableAttributedString
      var style: NSMutableParagraphStyle
    }

    let theme: ConversationTheme
    let size: Double
    var paragraphs: [Paragraph] = []

    init(theme: ConversationTheme, size: Double) {
      self.theme = theme
      self.size = size
    }

    mutating func append(_ blocks: [MarkdownBlock], context: Context, spacing: CGFloat) {
      var context = context
      for block in blocks {
        append(block, context: context, spacing: spacing)
        // Only the first paragraph of an item carries its marker.
        context.marker = nil
        if !paragraphs.isEmpty { paragraphs[paragraphs.count - 1].style.paragraphSpacing = spacing }
      }
    }

    private mutating func append(_ block: MarkdownBlock, context: Context, spacing: CGFloat) {
      switch block {
      case .heading(let level, let runs):
        let scale = level == 1 ? 1.35 : level == 2 ? 1.2 : 1.08
        let style = paragraphStyle(context)
        if !paragraphs.isEmpty { style.paragraphSpacingBefore = 4 }
        emit(runs, size: size * scale, bold: true, context: context, style: style)
      case .paragraph(let runs):
        let style = paragraphStyle(context)
        style.lineSpacing = size * 0.25
        emit(runs, size: size, bold: false, context: context, style: style)
      case .list(let ordered, let start, let items):
        let markers = items.enumerated().map { index, item in
          marker(ordered: ordered, number: start + index, checkbox: item.checkbox)
        }
        // The widest marker sets the column the items' text starts at, as the HStack did.
        let column = ceil(markers.map { $0.size().width }.max() ?? 0) + 8
        for (item, marker) in zip(items, markers) {
          var inner = context
          inner.indent = context.indent + column
          inner.marker = marker
          inner.markerIndent = context.indent
          if item.blocks.isEmpty {
            emit([], size: size, bold: false, context: inner, style: paragraphStyle(inner))
          } else {
            append(item.blocks, context: inner, spacing: 4)
          }
        }
      case .quote(let blocks):
        var inner = context
        inner.quotes.append(context.indent)
        inner.indent = context.indent + ProseTextView.quoteBarWidth + 10
        inner.color = theme.secondaryText.nsColor
        append(blocks, context: inner, spacing: 6)
      case .code, .table, .rule:
        // Not prose: `segments` keeps them out of here.
        break
      }
    }

    private func paragraphStyle(_ context: Context) -> NSMutableParagraphStyle {
      let style = NSMutableParagraphStyle()
      style.headIndent = context.indent
      style.firstLineHeadIndent = context.indent
      if context.marker != nil {
        // The marker hangs to the left of the column; the text starts at a tab on it.
        style.firstLineHeadIndent = context.markerIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: context.indent)]
      }
      return style
    }

    private mutating func emit(
      _ runs: [InlineRun], size: Double, bold: Bool, context: Context,
      style: NSMutableParagraphStyle
    ) {
      let text = NSMutableAttributedString()
      if let marker = context.marker {
        text.append(marker)
        text.append(NSAttributedString(string: "\t", attributes: [.font: font(size: size)]))
      }
      for run in runs {
        text.append(attributed(run, size: size, bold: bold, color: context.color))
      }
      if !context.quotes.isEmpty {
        text.addAttribute(
          .quoteBars, value: context.quotes, range: NSRange(location: 0, length: text.length))
      }
      paragraphs.append(Paragraph(text: text, style: style))
    }

    private func attributed(_ run: InlineRun, size: Double, bold: Bool, color: NSColor)
      -> NSAttributedString
    {
      var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
      if run.isCode {
        attributes[.font] = theme.nsCodeFont(size: size * 0.9)
        attributes[.backgroundColor] = theme.codeBackground.nsColor
      } else {
        attributes[.font] = theme.nsMessageFont(
          size: size, bold: bold || run.isBold, italic: run.isItalic)
      }
      if run.isStrikethrough {
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      if let link = run.link {
        attributes[.link] = link
      }
      return NSAttributedString(string: run.text, attributes: attributes)
    }

    private func font(size: Double) -> NSFont {
      theme.nsMessageFont(size: size, bold: false, italic: false)
    }

    private func marker(ordered: Bool, number: Int, checkbox: Bool?)
      -> NSAttributedString
    {
      let text: String
      var color = theme.secondaryText.nsColor
      if let checkbox {
        text = checkbox ? "☑" : "☐"
        if checkbox { color = theme.success.nsColor }
      } else {
        text = ordered ? "\(number)." : "•"
      }
      let font = theme.nsMessageFont(
        size: size, bold: false, italic: false, monospacedDigits: ordered)
      return NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: font])
    }

    func result() -> NSAttributedString {
      let result = NSMutableAttributedString()
      for (index, paragraph) in paragraphs.enumerated() {
        let text = paragraph.text
        if index < paragraphs.count - 1 {
          var attributes: [NSAttributedString.Key: Any] = [.font: font(size: size)]
          // The bar runs on, through the space between the quote's paragraphs.
          if let bars = text.length > 0
            ? text.attribute(.quoteBars, at: text.length - 1, effectiveRange: nil) : nil
          {
            attributes[.quoteBars] = bars
          }
          text.append(NSAttributedString(string: "\n", attributes: attributes))
        } else {
          // What follows the last paragraph is the next view's business, spaced by its stack.
          paragraph.style.paragraphSpacing = 0
        }
        text.addAttribute(
          .paragraphStyle, value: paragraph.style, range: NSRange(location: 0, length: text.length))
        result.append(text)
      }
      return result
    }
  }
}

extension NSAttributedString.Key {
  /// Where the bars of the quotes a paragraph is in are drawn: `[CGFloat]`.
  static let quoteBars = NSAttributedString.Key("VibeMarkdownQuoteBars")
}

extension ThemeColor {
  var nsColor: NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
  }
}

extension ConversationTheme {
  /// `messageFont(size:)`, for AppKit.
  func nsMessageFont(size: Double, bold: Bool, italic: Bool, monospacedDigits: Bool = false)
    -> NSFont
  {
    var font: NSFont
    if let family = messageFontFamily,
      let custom = NSFont(name: family, size: size)
        ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    {
      font = custom
    } else {
      font =
        monospacedDigits
        ? .monospacedDigitSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
      let design: NSFontDescriptor.SystemDesign? =
        switch fontStyle {
        case .system: nil
        case .serif: .serif
        case .monospaced: .monospaced
        }
      if let design, let descriptor = font.fontDescriptor.withDesign(design) {
        font = NSFont(descriptor: descriptor, size: size) ?? font
      }
    }
    var traits = font.fontDescriptor.symbolicTraits
    if bold { traits.insert(.bold) }
    if italic { traits.insert(.italic) }
    if traits != font.fontDescriptor.symbolicTraits {
      font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size) ?? font
    }
    return font
  }

  /// `codeFont(size:)`, for AppKit.
  func nsCodeFont(size: Double) -> NSFont {
    codeFontFamily.flatMap { NSFont(name: $0, size: size) }
      ?? .monospacedSystemFont(ofSize: size, weight: .regular)
  }
}

/// A run of prose, selectable from its first word to its last.
struct MarkdownTextView: NSViewRepresentable {
  let blocks: [MarkdownBlock]
  /// The whole message, for Copy as Markdown.
  var markdown: String?
  var secondary = false
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @Environment(\.openURL) private var openURL

  struct Input: Equatable {
    var blocks: [MarkdownBlock]
    var theme: ConversationTheme
    var size: Double
    var spacing: Double
    var secondary: Bool
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var input: Input?
    var openURL: OpenURLAction?

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else {
        return false
      }
      // Only what the parser let through is a link; `openURL` is what SwiftUI's links used.
      guard MarkdownDocument.safeLink(url.absoluteString) != nil else { return true }
      openURL?(url)
      return true
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> ProseTextView {
    let view = ProseTextView()
    view.delegate = context.coordinator
    return view
  }

  func updateNSView(_ view: ProseTextView, context: Context) {
    context.coordinator.openURL = openURL
    view.markdown = markdown
    let size = appearance.textSize.pointSize
    let input = Input(
      blocks: blocks, theme: theme, size: size,
      spacing: appearance.density == .compact ? 6 : 10, secondary: secondary)
    // Rebuilt only when what it shows changed: rebuilding would drop the reader's selection.
    guard context.coordinator.input != input else { return }
    context.coordinator.input = input
    view.quoteBarColor = theme.border.nsColor
    view.linkTextAttributes = [
      .foregroundColor: theme.accent.nsColor,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
      .cursor: NSCursor.pointingHand,
    ]
    view.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
    view.show(
      MarkdownProse.attributedString(
        blocks, theme: theme, size: size, spacing: input.spacing, secondary: secondary))
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ProseTextView, context: Context)
    -> CGSize?
  {
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 10_000
    let height = view.height(forWidth: width)
    return CGSize(width: proposal.width == nil ? view.naturalWidth : width, height: height)
  }
}

/// A text view that reads and selects, never edits, sized by SwiftUI rather than by a scroll view.
final class ProseTextView: NSTextView {
  nonisolated static let quoteBarWidth: CGFloat = 3

  /// The message's Markdown, for Copy as Markdown.
  var markdown: String?
  var quoteBarColor = NSColor.separatorColor

  convenience init() {
    // TextKit 1: the quotes' bars are drawn from its layout manager.
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
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

  /// The width the text takes when nothing wraps it.
  var naturalWidth: CGFloat {
    size(forWidth: 10_000).width
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

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event) ?? NSMenu()
    guard let markdown else { return menu }
    let item = NSMenuItem(
      title: String(localized: "Copy as Markdown", bundle: .module),
      action: #selector(copyMarkdown(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = markdown
    let copyIndex = menu.items.firstIndex { $0.action == #selector(copy(_:)) }
    menu.insertItem(item, at: copyIndex.map { $0 + 1 } ?? 0)
    return menu
  }

  @objc private func copyMarkdown(_ sender: NSMenuItem) {
    guard let markdown = sender.representedObject as? String else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(markdown, forType: .string)
  }
}
