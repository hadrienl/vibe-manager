import Foundation

/// The name a session gives to everything it creates: its branch in every repository, and the
/// folder its worktrees live in.
///
/// Computed once, from the title, when the session is created, and never again. A session is
/// renamed often and for cosmetic reasons; its branch is a reference that the forge, the CI and a
/// colleague may already know under its first name.
public struct SessionSlug: Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: String

  /// Every branch Vibe Manager creates starts with this, so its owner recognises them at a glance
  /// and can clean them up in one pass.
  public static let branchPrefix = "vibe/"
  /// Where a derived slug is cut. It leaves room for the prefix and for collision suffixes inside
  /// the 255 bytes a reference file name may take.
  public static let derivedLength = 40
  /// What a slug typed by hand may reach. Longer than a derived one, because a person who types
  /// a long name means it, and still far from the file name limit.
  public static let maximumLength = 64

  /// A slug known to be valid. `nil` when `validationProblem(for:)` has something to say.
  public init?(_ rawValue: String) {
    guard Self.validationProblem(for: rawValue) == nil else { return nil }
    self.rawValue = rawValue
  }

  public var description: String { rawValue }

  /// The branch every repository of the session is on.
  public var branchName: String { Self.branchPrefix + rawValue }

  /// The slug a title leads to.
  ///
  /// NFKD decomposition and transliteration to ASCII, lower case, every run of anything outside
  /// `[a-z0-9]` turned into one dash, cut at 40 characters on a word boundary. A title that leaves
  /// nothing — only punctuation, only emoji, nothing at all — falls back to `session-` and six hex
  /// digits, taken from `fallback` so the result stays predictable in a test.
  public static func derived(
    fromTitle title: String,
    fallback: () -> String = { randomSuffix() }
  ) -> SessionSlug {
    let ascii = transliterated(title).lowercased()
    var slug = ""
    var pendingDash = false
    for scalar in ascii.unicodeScalars {
      let isAllowed = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
      guard isAllowed else {
        pendingDash = !slug.isEmpty
        continue
      }
      if pendingDash {
        slug.append("-")
        pendingDash = false
      }
      slug.unicodeScalars.append(scalar)
    }
    slug = cut(slug, to: derivedLength)
    // The only way out of `derived` that is not a valid slug is an empty one; the fallback is
    // made of the same alphabet, so it always is.
    return SessionSlug(slug) ?? SessionSlug(unchecked: "session-\(fallback())")
  }

  /// What is wrong with a slug typed by hand, or `nil` when it produces a branch Git accepts.
  ///
  /// The rules are those of `git check-ref-format --branch` applied to `vibe/<slug>`, with the
  /// stricter parts the slug owes to also being a folder name: no slash, no leading dot or dash.
  public static func validationProblem(for candidate: String) -> SessionSlugProblem? {
    guard !candidate.isEmpty else { return .empty }
    guard candidate.utf8.count <= maximumLength else { return .tooLong(limit: maximumLength) }
    if candidate.hasPrefix(".") { return .leadingDot }
    if candidate.hasPrefix("-") { return .leadingDash }
    if candidate.hasSuffix(".") { return .trailingDot }
    if candidate.hasSuffix(".lock") { return .lockSuffix }
    if candidate.contains("..") { return .doubleDot }
    if candidate.contains("@{") || candidate == "@" { return .reservedSequence }
    for scalar in candidate.unicodeScalars {
      if scalar.value < 0x20 || scalar.value == 0x7F || forbidden.contains(scalar) {
        return .forbiddenCharacter(String(scalar))
      }
    }
    return nil
  }

  /// The first of `slug`, `slug-2`, `slug-3`… that `isTaken` does not claim.
  ///
  /// Proposed, never imposed: the caller shows it next to the field and the user decides.
  /// Reusing an existing branch is sometimes exactly the right thing to do.
  public func firstAvailable(where isTaken: (SessionSlug) -> Bool) -> SessionSlug {
    guard isTaken(self) else { return self }
    var index = 2
    while true {
      let suffix = "-\(index)"
      let base = Self.cut(rawValue, to: Self.maximumLength - suffix.count, onWords: false)
      let candidate = SessionSlug(unchecked: base + suffix)
      if !isTaken(candidate) { return candidate }
      index += 1
    }
  }

  private init(unchecked rawValue: String) {
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    guard Self.validationProblem(for: value) == nil else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Invalid session slug"
        )
      )
    }
    rawValue = value
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private static let forbidden: Set<Unicode.Scalar> = [
    " ", "~", "^", ":", "?", "*", "[", "\\", "/",
  ]

  public static func randomSuffix() -> String {
    String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF))
  }

  /// Decomposes, transliterates what has an ASCII spelling (œ, ß, Ł…) and drops what is left.
  private static func transliterated(_ text: String) -> String {
    let decomposed = text.decomposedStringWithCompatibilityMapping
    let latin = decomposed.applyingTransform(.toLatin, reverse: false) ?? decomposed
    let ascii = latin.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) ?? latin
    return ascii.applyingTransform(.stripCombiningMarks, reverse: false) ?? ascii
  }

  /// Cuts on the last dash that fits, so a slug never ends in half a word; a single word longer
  /// than the limit is cut where it is.
  private static func cut(_ slug: String, to limit: Int, onWords: Bool = true) -> String {
    guard slug.count > limit else { return slug }
    let prefix = String(slug.prefix(limit))
    var result = prefix
    if onWords, slug[slug.index(slug.startIndex, offsetBy: limit)] != "-",
      let lastDash = prefix.lastIndex(of: "-")
    {
      result = String(prefix[..<lastDash])
    }
    while result.hasSuffix("-") || result.hasSuffix(".") { result.removeLast() }
    return result
  }
}

/// Why a slug typed by hand cannot become a branch — said in the field, not discovered in the
/// output of a `git worktree add`.
public enum SessionSlugProblem: Hashable, Sendable {
  case empty
  case tooLong(limit: Int)
  case leadingDot
  case leadingDash
  case trailingDot
  case lockSuffix
  case doubleDot
  case reservedSequence
  case forbiddenCharacter(String)

  public var message: String {
    switch self {
    case .empty:
      return "The branch name cannot be empty."
    case .tooLong(let limit):
      return "The branch name is longer than \(limit) characters."
    case .leadingDot:
      return "The branch name cannot start with a dot."
    case .leadingDash:
      return "The branch name cannot start with a dash."
    case .trailingDot:
      return "The branch name cannot end with a dot."
    case .lockSuffix:
      return "Git reserves names ending in .lock."
    case .doubleDot:
      return "The branch name cannot contain two dots in a row."
    case .reservedSequence:
      return "Git reserves @{ and a lone @."
    case .forbiddenCharacter(let character):
      let shown = character == " " ? "a space" : "“\(character)”"
      return "The branch name cannot contain \(shown)."
    }
  }
}
