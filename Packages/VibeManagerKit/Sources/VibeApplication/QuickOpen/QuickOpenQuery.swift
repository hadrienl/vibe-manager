import Foundation
import VibeDomain

/// What the user typed in Open Quickly (#37), understood.
///
/// A ticket, a request, a branch or a folder is brought to the same canonical form as the
/// resources of the journal (#36), by the same functions: a URL pasted from the browser is compared
/// key to key, whatever tab, anchor or trailing slash it carries. Free text is only what is left.
public struct QuickOpenQuery: Hashable, Sendable {
  /// How a number was written: `#` names a ticket or, on GitHub, a pull request too; `!` a GitLab
  /// merge request; a bare number any of them.
  public enum NumberSign: Hashable, Sendable {
    case hash
    case bang
    case bare
  }

  public enum Criterion: Hashable, Sendable {
    /// A ticket or request URL, by the key of its resource.
    case resourceKey(String)
    /// `36`, `#36`, `!12`, `owner/repo#36`. The context, lowercased, is compared by its end.
    case number(Int, sign: NumberSign, context: [String])
    /// A branch named exactly, by a forge URL of its page.
    case branch(String)
    /// A folder, absolute and canonical.
    case path(String)
    /// Words, each to be found somewhere in the session. Folded: no case, no accents.
    case text([String])
  }

  /// What was typed, trimmed.
  public let text: String
  public let criteria: [Criterion]

  public var isEmpty: Bool { criteria.isEmpty }

  public init(_ typed: String) {
    let text = Self.unwrapped(typed)
    self.text = text
    criteria = Self.criteria(for: text)
  }

  // MARK: - Reading the input

  /// A URL copied from Markdown or a chat comes with what surrounds it: `<…>`, `(…)`, quotes, and
  /// the punctuation of its sentence.
  static func unwrapped(_ typed: String) -> String {
    var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.contains("://") {
      while let last = text.last, ".,;:!?".contains(last) { text.removeLast() }
    }
    let pairs: [(Character, Character)] = [("<", ">"), ("(", ")"), ("\"", "\""), ("'", "'"), ("`", "`")]
    var changed = true
    while changed, text.count >= 2 {
      changed = false
      for (open, close) in pairs where text.first == open && text.last == close {
        text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        changed = true
      }
    }
    if text.hasPrefix("http://") || text.hasPrefix("https://") {
      text = ResourceRecognizer.trimmed(text)
    }
    return text
  }

  private static func criteria(for text: String) -> [Criterion] {
    guard !text.isEmpty else { return [] }
    if text.hasPrefix("http://") || text.hasPrefix("https://") {
      return urlCriteria(text)
    }
    if let number = number(in: text) {
      var criteria: [Criterion] = [number]
      // A bare number is also a fragment of a branch or a title: `36` finds `feat/36-journal`.
      if case .number(_, .bare, _) = number { criteria.append(.text(words(text))) }
      return criteria
    }
    if text.hasPrefix("/") || text == "~" || text.hasPrefix("~/") {
      let expanded = (text as NSString).expandingTildeInPath
      return [.path(CanonicalPath.of((expanded as NSString).standardizingPath))]
    }
    let words = words(text)
    return words.isEmpty ? [] : [.text(words)]
  }

  static func words(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map { Folding.fold(String($0)) }
  }

  // MARK: - Numbers

  /// `36`, `#36`, `!12`, `owner/repo#36`, `group/sub/project!12`.
  static func number(in text: String) -> Criterion? {
    if let value = positive(text) { return .number(value, sign: .bare, context: []) }
    guard let separator = text.lastIndex(where: { $0 == "#" || $0 == "!" }),
      let value = positive(String(text[text.index(after: separator)...]))
    else { return nil }
    let sign: NumberSign = text[separator] == "!" ? .bang : .hash
    let prefix = text[..<separator]
    guard !prefix.contains(where: \.isWhitespace) else { return nil }
    let context = prefix.lowercased().split(separator: "/").map(String.init)
    return .number(value, sign: sign, context: context)
  }

  private static func positive(_ text: String) -> Int? {
    guard !text.isEmpty, text.count <= 9, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber),
      let value = Int(text), value > 0
    else { return nil }
    return value
  }

  // MARK: - URLs

  private static func urlCriteria(_ text: String) -> [Criterion] {
    guard let url = URL(string: text) else { return [.text(words(text))] }
    if let resource = ResourceRecognizer.resource(for: url, involvement: .viewed, at: .distantPast)
    {
      return [.resourceKey(resource.key)]
    }
    let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
    if let branch = branch(in: components) {
      return [.branch(branch)]
    }
    // Another page of a forge — the repository, a commit, a file: its project is what it names.
    let project: [String]
    if let separator = components.firstIndex(of: "-") {
      project = Array(components[..<separator])
    } else {
      project = Array(components.prefix(2))
    }
    guard project.count >= 2 else { return [.text(words(text))] }
    return [.text([Folding.fold(project.joined(separator: "/"))])]
  }

  /// The branch a forge URL shows: `…/tree/<branch>`, `…/-/tree/<branch>`,
  /// `…/compare/<base>...<branch>`. A branch name may hold slashes: all that follows is its name.
  static func branch(in components: [String]) -> String? {
    for (index, component) in components.enumerated() where index >= 2 {
      let rest = components[(index + 1)...].joined(separator: "/")
      guard !rest.isEmpty else { continue }
      switch component {
      case "tree":
        return ResourceRecognizer.normalizedBranch(rest)
      case "compare":
        let head = rest.components(separatedBy: "...").last ?? rest
        return ResourceRecognizer.normalizedBranch(head)
      default:
        continue
      }
    }
    return nil
  }
}

/// Text made comparable the way the Finder compares it: no case, no accents, no width.
public enum Folding {
  public static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
  }
}
