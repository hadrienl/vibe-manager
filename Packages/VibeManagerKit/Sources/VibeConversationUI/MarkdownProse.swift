import AppKit
import SwiftUI
import VibeApplication

/// A message's text as attributed strings, for the text views that draw it (`SegmentTextView`).
///
/// A run of prose — headings, paragraphs, lists and quotes that follow one another — is one
/// string, selectable from one paragraph to the next: SwiftUI cannot select across two `Text`s
/// on macOS 14. Code blocks and tables are strings of their own, in views that keep their Copy
/// button and their horizontal scrolling; the message's selection crosses them (#189).
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
        style.lineSpacing = size * (theme.layout.lineHeight - 1)
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
        inner.indent = context.indent + SegmentTextView.quoteBarWidth + 10
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

    func attributed(_ run: InlineRun, size: Double, bold: Bool, color: NSColor)
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

    func font(size: Double) -> NSFont {
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

extension MarkdownProse {
  /// A code block's text, coloured by its words, its lines a little apart.
  static func code(
    _ code: String, language: String?, theme: ConversationTheme, size: Double
  ) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 2
    let font = theme.nsCodeFont(size: size)
    let result = NSMutableAttributedString()
    for segment in SyntaxHighlighter.segments(of: code, language: language) {
      result.append(
        NSAttributedString(
          string: String(segment.text),
          attributes: [
            .font: font, .paragraphStyle: style,
            .foregroundColor: CodeBlockView.color(for: segment.kind, theme: theme).nsColor,
          ]))
    }
    return result
  }

  /// A table, as TextKit lays one out (`NSTextTable`): its header on the surface's colour, a line
  /// under each row. Each column is as wide as its widest cell, up to 320 points, beyond which its
  /// cells wrap — without widths, a table would take all the width it is given.
  static func table(
    header: [[InlineRun]], rows: [[[InlineRun]]], theme: ConversationTheme, size: Double
  ) -> NSAttributedString {
    let builder = Builder(theme: theme, size: size)
    let lines = [header] + rows
    let columns = lines.map(\.count).max() ?? 0
    guard columns > 0 else { return NSAttributedString() }
    let cells = lines.enumerated().map { index, line in
      (0..<columns).map { column in
        let text = NSMutableAttributedString()
        for run in column < line.count ? line[column] : [] {
          text.append(
            builder.attributed(run, size: size, bold: index == 0, color: theme.text.nsColor))
        }
        return text
      }
    }
    let widths = (0..<columns).map { column in
      min(ceil(cells.map { $0[column].size().width }.max() ?? 0) + 1, 320)
    }
    let table = NSTextTable()
    table.numberOfColumns = columns
    table.collapsesBorders = true
    table.hidesEmptyCells = false
    let result = NSMutableAttributedString()
    for (row, line) in cells.enumerated() {
      for (column, cell) in line.enumerated() {
        let block = NSTextTableBlock(
          table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        block.setValue(widths[column], type: .absoluteValueType, for: .width)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
        if row < cells.count - 1 {
          block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
          block.setBorderColor(theme.border.nsColor, for: .maxY)
        }
        if row == 0 { block.backgroundColor = theme.surface.nsColor }
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        let text = NSMutableAttributedString(attributedString: cell)
        text.append(
          NSAttributedString(
            string: "\n", attributes: [.font: builder.font(size: size)]))
        text.addAttribute(
          .paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        result.append(text)
      }
    }
    return result
  }

  /// Text as it was typed, in the messages' font: what the user sent.
  static func plain(_ text: String, theme: ConversationTheme, size: Double, color: ThemeColor)
    -> NSAttributedString
  {
    NSAttributedString(
      string: text,
      attributes: [
        .font: theme.nsMessageFont(size: size, bold: false, italic: false),
        .foregroundColor: color.nsColor,
      ])
  }
}
