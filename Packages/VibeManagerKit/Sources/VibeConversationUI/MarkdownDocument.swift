import Foundation
import Markdown
import SwiftUI

/// A piece of text inside a block, with its emphasis.
public struct InlineRun: Hashable, Sendable {
  public var text: String
  public var isBold = false
  public var isItalic = false
  public var isCode = false
  public var isStrikethrough = false
  /// Only `http`, `https` and `mailto` survive: a transcript holds what a web page or a server
  /// made the agent write, and a link to anything else must not be one click away (ADR 0023).
  public var link: URL?

  public init(text: String) {
    self.text = text
  }
}

public struct MarkdownListItem: Hashable, Sendable {
  /// `true` or `false` for a task list item, `nil` for a plain one.
  public var checkbox: Bool?
  public var blocks: [MarkdownBlock]
}

/// What a message is made of, parsed once and drawn by SwiftUI views.
public indirect enum MarkdownBlock: Hashable, Sendable {
  case heading(level: Int, runs: [InlineRun])
  case paragraph([InlineRun])
  case list(ordered: Bool, start: Int, items: [MarkdownListItem])
  case quote([MarkdownBlock])
  case code(language: String?, code: String)
  case table(header: [[InlineRun]], rows: [[[InlineRun]]])
  case rule
}

/// Parses GitHub-flavoured Markdown (swift-markdown, cmark-gfm) into blocks.
///
/// No HTML is interpreted — it is shown as the text it is — and no image is loaded: an image
/// becomes a link to it, which a tracking pixel cannot use.
public enum MarkdownDocument {
  public static func blocks(from text: String) -> [MarkdownBlock] {
    let document = Document(parsing: text, options: [.parseBlockDirectives])
    return document.children.compactMap(block)
  }

  static func block(_ markup: any Markup) -> MarkdownBlock? {
    switch markup {
    case let heading as Heading:
      return .heading(level: heading.level, runs: runs(heading.children))
    case let paragraph as Paragraph:
      return .paragraph(runs(paragraph.children))
    case let list as UnorderedList:
      return .list(ordered: false, start: 1, items: items(list.listItems))
    case let list as OrderedList:
      return .list(ordered: true, start: Int(list.startIndex), items: items(list.listItems))
    case let quote as BlockQuote:
      return .quote(quote.children.compactMap(block))
    case let code as CodeBlock:
      var text = code.code
      if text.hasSuffix("\n") { text.removeLast() }
      return .code(language: code.language.flatMap { $0.isEmpty ? nil : $0 }, code: text)
    case let table as Markdown.Table:
      let header: [[InlineRun]] = table.head.cells.map { runs($0.children) }
      let rows: [[[InlineRun]]] = table.body.rows.map { row in
        row.cells.map { cell -> [InlineRun] in runs(cell.children) }
      }
      return .table(header: header, rows: rows)
    case is ThematicBreak:
      return .rule
    case let html as HTMLBlock:
      return .paragraph([InlineRun(text: html.rawHTML.trimmingCharacters(in: .newlines))])
    default:
      let text = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : .paragraph([InlineRun(text: text)])
    }
  }

  static func items(_ items: some Sequence<ListItem>) -> [MarkdownListItem] {
    items.map { item in
      let checkbox: Bool? = item.checkbox.map { $0 == .checked }
      return MarkdownListItem(checkbox: checkbox, blocks: item.children.compactMap(block))
    }
  }

  static func runs(_ children: some Sequence<any Markup>) -> [InlineRun] {
    var result: [InlineRun] = []
    for child in children { collect(child, style: InlineRun(text: ""), into: &result) }
    return result
  }

  private static func collect(_ markup: any Markup, style: InlineRun, into runs: inout [InlineRun])
  {
    var run = style
    switch markup {
    case let text as Markdown.Text:
      run.text = text.string
      runs.append(run)
    case is SoftBreak:
      run.text = " "
      runs.append(run)
    case is LineBreak:
      run.text = "\n"
      runs.append(run)
    case let code as InlineCode:
      run.text = code.code
      run.isCode = true
      runs.append(run)
    case let html as InlineHTML:
      run.text = html.rawHTML
      runs.append(run)
    case let image as Markdown.Image:
      run.text = image.plainText.isEmpty ? (image.source ?? "") : image.plainText
      run.link = safeLink(image.source)
      runs.append(run)
    default:
      if markup is Emphasis { run.isItalic = true }
      if markup is Strong { run.isBold = true }
      if markup is Strikethrough { run.isStrikethrough = true }
      if let link = markup as? Markdown.Link { run.link = safeLink(link.destination) }
      for child in markup.children { collect(child, style: run, into: &runs) }
    }
  }

  static func safeLink(_ destination: String?) -> URL? {
    guard let destination, let url = URL(string: destination),
      let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme)
    else { return nil }
    return url
  }

  /// The runs as one attributed string, drawn with the theme.
  static func attributed(
    _ runs: [InlineRun], theme: ConversationTheme, size: Double, weight: Font.Weight? = nil
  ) -> AttributedString {
    var result = AttributedString()
    for run in runs {
      var piece = AttributedString(run.text)
      if run.isCode {
        piece.font = theme.codeFont(size: size * 0.9)
        piece.backgroundColor = theme.codeBackground.color
      } else {
        var font = theme.messageFont(size: size)
        if let weight { font = font.weight(weight) }
        if run.isBold { font = font.bold() }
        if run.isItalic { font = font.italic() }
        piece.font = font
      }
      if run.isStrikethrough { piece.strikethroughStyle = .single }
      if let link = run.link {
        piece.link = link
        piece.foregroundColor = theme.accent.color
        piece.underlineStyle = .single
      }
      result += piece
    }
    return result
  }

  /// The runs as plain text, for copying and for VoiceOver.
  static func plainText(_ runs: [InlineRun]) -> String {
    runs.map(\.text).joined()
  }
}

/// Parsed messages, kept so that scrolling back up does not parse them again.
@MainActor
public final class MarkdownCache {
  public static let shared = MarkdownCache()
  private var blocks: [String: [MarkdownBlock]] = [:]
  private var order: [String] = []
  private let capacity = 2_000

  /// Forgets every parsed message: what was said lives only as long as a view shows it.
  public func removeAll() {
    blocks.removeAll()
    order.removeAll()
  }

  func blocks(for text: String) -> [MarkdownBlock] {
    if let cached = blocks[text] { return cached }
    let parsed = MarkdownDocument.blocks(from: text)
    blocks[text] = parsed
    order.append(text)
    if order.count > capacity {
      blocks[order.removeFirst()] = nil
    }
    return parsed
  }
}
