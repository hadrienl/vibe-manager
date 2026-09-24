import Foundation

/// Reads `{{name}}` placeholders out of a template's text.
///
/// Strict on purpose: a name is a letter followed by letters, digits, `-` and `_`, optionally
/// marked `?`. Everything else between double braces — `{{payload.url}}`, `{{ items[0] }}`,
/// `{{#each}}` — is text, because prompts are full of code that uses the same braces, and a field
/// the user never meant to create is worse than no field. `\{{` writes the braces themselves.
///
/// `{{url|/merge_requests\/(\d+)/}}` keeps only part of the field's value: the regular expression
/// runs from `|/` to the next `/` that is not escaped, so a slash inside it is written `\/`, and
/// braces or bars inside it are its own.
///
/// Positions are counted in UTF-16 code units, the unit an `NSTextView` highlights by.
public enum PromptTemplateSyntax {
  public static let maximumNameLength = 40
  /// Past this, what follows `|/` is not read as a pattern.
  public static let maximumPatternLength = 300

  public struct Placeholder: Hashable, Sendable {
    /// The field's identity, lowercased.
    public let key: String
    /// The name as written, for a label derived from it.
    public let spelling: String
    public let isOptional: Bool
    /// The regular expression written after `|`, without its slashes; `nil` for the whole value.
    public let pattern: String?
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
      if let placeholder = placeholder(in: units, at: index) {
        flushRun(upTo: index)
        if !buffer.isEmpty {
          segments.append(.text(buffer))
          buffer = ""
        }
        segments.append(.placeholder(placeholder))
        placeholders.append(placeholder)
        index = placeholder.range.upperBound
        runStart = index
        continue
      }
      guard let close = closingBraces(in: units, from: index + 2) else {
        index += 2
        continue
      }
      malformed.append(index..<(close + 2))
      index = close + 2
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
      let pattern = placeholder.pattern.map { "|/\($0)/" } ?? ""
      let replacement = "{{\(placeholder.spelling)\(isOptional ? "?" : "")\(pattern)}}"
      units.replaceSubrange(placeholder.range, with: Array(replacement.utf16))
    }
    return String(decoding: units, as: UTF16.self)
  }

  /// The placeholder opened by the `{{` at `start` — `{{ name? |/pattern/ }}` — or `nil` when the
  /// braces hold anything else.
  static func placeholder(in units: [UInt16], at start: Int) -> Placeholder? {
    var index = start + 2
    func skipSpaces() {
      while index < units.count, units[index] == space || units[index] == tab { index += 1 }
    }
    skipSpaces()
    let nameStart = index
    guard index < units.count, isASCIILetter(units[index]) else { return nil }
    while index < units.count, isNameCharacter(units[index]) { index += 1 }
    guard index - nameStart <= maximumNameLength else { return nil }
    let spelling = String(decoding: units[nameStart..<index], as: UTF16.self)
    var isOptional = false
    if index < units.count, units[index] == question {
      isOptional = true
      index += 1
    }
    skipSpaces()
    var pattern: String?
    if index < units.count, units[index] == bar {
      index += 1
      skipSpaces()
      guard index < units.count, units[index] == slash else { return nil }
      index += 1
      let patternStart = index
      while true {
        guard index < units.count, index - patternStart <= maximumPatternLength,
          units[index] != newline
        else { return nil }
        if units[index] == backslash {
          index += 2
          continue
        }
        if units[index] == slash { break }
        index += 1
      }
      pattern = String(decoding: units[patternStart..<index], as: UTF16.self)
      index += 1
      skipSpaces()
    }
    guard index + 1 < units.count, units[index] == closeBrace, units[index + 1] == closeBrace
    else { return nil }
    return Placeholder(
      key: spelling.lowercased(), spelling: spelling, isOptional: isOptional, pattern: pattern,
      range: start..<(index + 2))
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

  private static func isASCIILetter(_ unit: UInt16) -> Bool {
    (0x61...0x7A).contains(unit) || (0x41...0x5A).contains(unit)
  }

  private static func isNameCharacter(_ unit: UInt16) -> Bool {
    isASCIILetter(unit) || (0x30...0x39).contains(unit) || unit == underscore || unit == hyphen
  }

  private static let backslash = UInt16(UInt8(ascii: "\\"))
  private static let openBrace = UInt16(UInt8(ascii: "{"))
  private static let closeBrace = UInt16(UInt8(ascii: "}"))
  private static let newline = UInt16(UInt8(ascii: "\n"))
  private static let space = UInt16(UInt8(ascii: " "))
  private static let tab = UInt16(UInt8(ascii: "\t"))
  private static let question = UInt16(UInt8(ascii: "?"))
  private static let bar = UInt16(UInt8(ascii: "|"))
  private static let slash = UInt16(UInt8(ascii: "/"))
  private static let underscore = UInt16(UInt8(ascii: "_"))
  private static let hyphen = UInt16(UInt8(ascii: "-"))
}
