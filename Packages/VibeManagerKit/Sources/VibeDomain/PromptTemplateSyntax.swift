import Foundation

/// Reads `{{name}}` placeholders out of a template's text.
///
/// Strict on purpose: a name is a letter followed by letters, digits, `-` and `_`, optionally
/// marked `?`. Everything else between double braces — `{{payload.url}}`, `{{ items[0] }}`,
/// `{{#each}}` — is text, because prompts are full of code that uses the same braces, and a field
/// the user never meant to create is worse than no field. `\{{` writes the braces themselves.
///
/// Positions are counted in UTF-16 code units, the unit an `NSTextView` highlights by.
public enum PromptTemplateSyntax {
  public static let maximumNameLength = 40

  public struct Placeholder: Hashable, Sendable {
    /// The field's identity, lowercased.
    public let key: String
    /// The name as written, for a label derived from it.
    public let spelling: String
    public let isOptional: Bool
    public let range: Range<Int>
  }

  public enum Segment: Hashable, Sendable {
    case text(String)
    case placeholder(Placeholder)
  }

  public struct Parsed: Hashable, Sendable {
    public let segments: [Segment]
    public let placeholders: [Placeholder]
    /// Double braces that are not a field, kept as text and worth pointing out in an editor.
    public let malformed: [Range<Int>]
  }

  public static func parse(_ text: String) -> Parsed {
    let units = Array(text.utf16)
    let count = units.count
    var segments: [Segment] = []
    var placeholders: [Placeholder] = []
    var malformed: [Range<Int>] = []
    var buffer = ""
    var runStart = 0
    var index = 0

    func decode(_ range: Range<Int>) -> String {
      String(decoding: units[range], as: UTF16.self)
    }
    func flushRun(upTo end: Int) {
      if runStart < end {
        buffer += decode(runStart..<end)
      }
    }

    while index < count {
      if units[index] == backslash, index + 2 < count,
        units[index + 1] == openBrace, units[index + 2] == openBrace
      {
        flushRun(upTo: index)
        buffer += "{{"
        index += 3
        runStart = index
        continue
      }
      guard units[index] == openBrace, index + 1 < count, units[index + 1] == openBrace else {
        index += 1
        continue
      }
      guard let close = closingBraces(in: units, from: index + 2) else {
        index += 2
        continue
      }
      let range = index..<(close + 2)
      if let (spelling, isOptional) = name(in: decode((index + 2)..<close)) {
        flushRun(upTo: index)
        if !buffer.isEmpty {
          segments.append(.text(buffer))
          buffer = ""
        }
        let placeholder = Placeholder(
          key: spelling.lowercased(), spelling: spelling, isOptional: isOptional, range: range)
        segments.append(.placeholder(placeholder))
        placeholders.append(placeholder)
        index = range.upperBound
        runStart = index
      } else {
        malformed.append(range)
        index = range.upperBound
      }
    }
    flushRun(upTo: count)
    if !buffer.isEmpty {
      segments.append(.text(buffer))
    }
    return Parsed(segments: segments, placeholders: placeholders, malformed: malformed)
  }

  /// The text with every occurrence of one field marked optional, or not.
  public static func settingOptional(_ isOptional: Bool, for key: String, in text: String)
    -> String
  {
    let key = key.lowercased()
    let targets = parse(text).placeholders.filter { $0.key == key }
    guard !targets.isEmpty else { return text }
    var units = Array(text.utf16)
    for placeholder in targets.reversed() {
      let replacement = "{{\(placeholder.spelling)\(isOptional ? "?" : "")}}"
      units.replaceSubrange(placeholder.range, with: Array(replacement.utf16))
    }
    return String(decoding: units, as: UTF16.self)
  }

  /// A name and its `?`, or `nil` when the braces hold anything else.
  static func name(in inner: String) -> (spelling: String, isOptional: Bool)? {
    var name = inner.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    var isOptional = false
    if name.hasSuffix("?") {
      isOptional = true
      name.removeLast()
    }
    guard let first = name.unicodeScalars.first, isASCIILetter(first),
      name.unicodeScalars.count <= maximumNameLength,
      name.unicodeScalars.allSatisfy({
        isASCIILetter($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
      })
    else {
      return nil
    }
    return (name, isOptional)
  }

  /// Where the `}}` closing the braces opened just before `start` is, on the same line and not
  /// too far: an unmatched `{{` must not swallow the rest of a paragraph.
  private static func closingBraces(in units: [UInt16], from start: Int) -> Int? {
    var index = start
    let limit = min(units.count - 1, start + maximumNameLength + 16)
    while index < limit {
      if units[index] == newline { return nil }
      // Another opening: the first braces were text, and this one may well be a field.
      if units[index] == openBrace, units[index + 1] == openBrace { return nil }
      if units[index] == closeBrace, units[index + 1] == closeBrace { return index }
      index += 1
    }
    return nil
  }

  private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
  }

  private static let backslash = UInt16(UInt8(ascii: "\\"))
  private static let openBrace = UInt16(UInt8(ascii: "{"))
  private static let closeBrace = UInt16(UInt8(ascii: "}"))
  private static let newline = UInt16(UInt8(ascii: "\n"))
}
