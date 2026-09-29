import Foundation
import Markdown

/// The part of a release's notes that the update window shows.
///
/// The body of a release ends with the release checklist, filled in with its measurements. Only
/// what comes before the marker is for users; a body without the marker is not shown at all, and
/// the feed links to the release page instead.
public enum ReleaseNotes {
  public static let marker = "<!-- release-checklist -->"

  /// The Markdown before the marker, or `nil` when there is no marker or nothing before it.
  public static func publicMarkdown(of body: String) -> String? {
    let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
    guard let range = normalized.range(of: marker) else { return nil }
    let notes = normalized[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    return notes.isEmpty ? nil : notes
  }

  /// The public notes as HTML, or `nil` when there are none.
  public static func html(of body: String) -> String? {
    guard let markdown = publicMarkdown(of: body) else { return nil }
    // HTMLFormatter writes text as it is: escape it first, so that `a < b` stays text.
    var escaper = TextEscaper()
    let document = escaper.visit(Document(parsing: markdown)) ?? Document()
    return HTMLFormatter.format(document)
  }
}

/// Escapes the text, code and link targets of a document for HTML, and leaves the HTML its author
/// wrote as it is.
private struct TextEscaper: MarkupRewriter {
  func visitText(_ text: Text) -> (any Markup)? {
    var text = text
    text.string = HTML.escapingText(text.string)
    return text
  }

  func visitInlineCode(_ inlineCode: InlineCode) -> (any Markup)? {
    var inlineCode = inlineCode
    inlineCode.code = HTML.escapingText(inlineCode.code)
    return inlineCode
  }

  func visitCodeBlock(_ codeBlock: CodeBlock) -> (any Markup)? {
    var codeBlock = codeBlock
    codeBlock.code = HTML.escapingText(codeBlock.code)
    return codeBlock
  }

  mutating func visitLink(_ link: Link) -> (any Markup)? {
    var link = link
    link.destination = link.destination.map(HTML.escapingAttribute)
    // Rewrite the label too.
    return defaultVisit(link)
  }

  func visitImage(_ image: Image) -> (any Markup)? {
    var image = image
    image.source = image.source.map(HTML.escapingAttribute)
    image.title = image.title.map(HTML.escapingAttribute)
    return image
  }
}

/// Escaping shared by the HTML of the notes and the XML of the feed.
enum HTML {
  static func escapingText(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
  }

  static func escapingAttribute(_ text: String) -> String {
    escapingText(text).replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }
}
