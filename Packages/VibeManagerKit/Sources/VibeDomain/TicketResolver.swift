import Foundation

/// What makes an address a ticket, and how its page's title reads (#89).
///
/// A configuration, never code: a pattern that recognises the address, the short identifier shown
/// in front of the title, and the rules that take the site's own words off the page's title. The
/// title itself is read from the page, in the session's web view, where the user is signed in.
public struct TicketResolver: Identifiable, Hashable, Codable, Sendable {
  /// Where a resolver shipped with the application came from, so that a later version can bring
  /// it up to date as long as the user left it alone.
  public struct PresetOrigin: Hashable, Codable, Sendable {
    public var id: String
    public var revision: Int
    /// The user changed its pattern, identifier or cleanup: it no longer follows the shipped one.
    public var isModified: Bool

    public init(id: String, revision: Int, isModified: Bool = false) {
      self.id = id
      self.revision = revision
      self.isModified = isModified
    }
  }

  public var id: UUID
  public var name: String
  public var isEnabled: Bool
  /// A regular expression with named captures, matched from the start of the address.
  public var pattern: String
  /// `{owner}/{repo}#{number}`, `{key}`: the captures, and `{host}`.
  public var shortID: String
  /// Regular expressions whose matches are removed from the title, in this order.
  public var titleCleanup: [String]
  public var preset: PresetOrigin?

  public init(
    id: UUID = UUID(),
    name: String,
    isEnabled: Bool = true,
    pattern: String,
    shortID: String,
    titleCleanup: [String] = [],
    preset: PresetOrigin? = nil
  ) {
    self.id = id
    self.name = name
    self.isEnabled = isEnabled
    self.pattern = pattern
    self.shortID = shortID
    self.titleCleanup = titleCleanup
    self.preset = preset
  }

  public var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Whether what makes this resolver work — not its name or switch — is the same as `other`'s.
  public func sameRules(as other: TicketResolver) -> Bool {
    pattern == other.pattern && shortID == other.shortID && titleCleanup == other.titleCleanup
  }
}

/// Why a resolver cannot be saved as it is.
public enum TicketResolverIssue: Hashable, Sendable {
  case nameMissing
  case patternMissing
  case patternInvalid
  /// The pattern names nothing: an identifier could only ever be the same for every ticket.
  case patternWithoutCaptures
  case shortIDMissing
  /// `{name}` in the identifier is neither a capture of the pattern nor `{host}`.
  case unknownPlaceholder(String)
  case cleanupInvalid(index: Int)
}

/// A resolver, compiled once: its expressions are not parsed again for every address.
public struct CompiledTicketResolver: Sendable {
  public let resolver: TicketResolver
  let expression: NSRegularExpression
  let captureNames: [String]
  let cleanup: [NSRegularExpression]

  public init?(_ resolver: TicketResolver) {
    guard resolver.validate().isEmpty,
      let expression = try? NSRegularExpression(pattern: resolver.pattern)
    else { return nil }
    self.resolver = resolver
    self.expression = expression
    captureNames = TicketResolverSyntax.captureNames(in: resolver.pattern)
    cleanup = resolver.titleCleanup.compactMap { try? NSRegularExpression(pattern: $0) }
  }

  /// The ticket this address is, when the pattern recognises it.
  ///
  /// The pattern is matched from the start of the address, and must end where the address does,
  /// or before a `/`, `?` or `#`: `…/issues/42` recognises `…/issues/42/files` but not
  /// `…/issues/42abc`. The scheme and the host are compared in lower case, as they mean.
  public func recognize(_ address: String) -> TicketRecognition? {
    guard let normalized = TicketResolverSyntax.normalized(address) else { return nil }
    let text = normalized as NSString
    guard
      let match = expression.firstMatch(
        in: normalized, options: [.anchored], range: NSRange(location: 0, length: text.length))
    else { return nil }
    let end = NSMaxRange(match.range)
    if end < text.length {
      let next = text.substring(with: NSRange(location: end, length: 1))
      guard ["/", "?", "#"].contains(next) else { return nil }
    }
    var captures: [String: String] = [:]
    for name in captureNames {
      let range = match.range(withName: name)
      guard range.location != NSNotFound else { continue }
      captures[name] = text.substring(with: range)
    }
    captures["host"] = captures["host"] ?? URLComponents(string: normalized)?.host ?? ""
    let shortID = TicketResolverSyntax.fill(resolver.shortID, with: captures)
    guard !shortID.isEmpty else { return nil }
    return TicketRecognition(
      resolverID: resolver.id, address: address, shortID: shortID, captures: captures)
  }

  /// The title a page gave, without what the site adds to it — or `nil` when nothing is left
  /// that names this ticket: an empty title, or one that only names the site.
  public func cleanTitle(_ raw: String) -> String? {
    var title = TicketTitleText.normalized(raw)
    for rule in cleanup {
      let range = NSRange(location: 0, length: (title as NSString).length)
      title = rule.stringByReplacingMatches(in: title, range: range, withTemplate: "")
      title = TicketTitleText.normalized(title)
    }
    guard !title.isEmpty,
      title.caseInsensitiveCompare(resolver.trimmedName) != .orderedSame
    else { return nil }
    return TicketTitleText.bounded(title)
  }
}

extension TicketResolver {
  /// Everything wrong with this resolver, all at once.
  public func validate() -> [TicketResolverIssue] {
    var issues: [TicketResolverIssue] = []
    if trimmedName.isEmpty { issues.append(.nameMissing) }
    let captures: [String]
    if pattern.trimmingCharacters(in: .whitespaces).isEmpty {
      issues.append(.patternMissing)
      captures = []
    } else if (try? NSRegularExpression(pattern: pattern)) == nil {
      issues.append(.patternInvalid)
      captures = []
    } else {
      captures = TicketResolverSyntax.captureNames(in: pattern)
      if captures.isEmpty { issues.append(.patternWithoutCaptures) }
    }
    if shortID.trimmingCharacters(in: .whitespaces).isEmpty {
      issues.append(.shortIDMissing)
    } else if !issues.contains(.patternInvalid), !issues.contains(.patternMissing) {
      let known = Set(captures + ["host"])
      for name in TicketResolverSyntax.placeholders(in: shortID) where !known.contains(name) {
        issues.append(.unknownPlaceholder(name))
      }
    }
    for (index, rule) in titleCleanup.enumerated()
    where (try? NSRegularExpression(pattern: rule)) == nil {
      issues.append(.cleanupInvalid(index: index))
    }
    return issues
  }
}

/// One address recognised as a ticket, at the moment a session was created.
public struct TicketRecognition: Hashable, Sendable {
  public let resolverID: UUID
  /// The address as it was written, less the punctuation that closed the sentence around it.
  public let address: String
  /// `acme/app#42`, `PROJ-123`.
  public let shortID: String
  public let captures: [String: String]

  public init(resolverID: UUID, address: String, shortID: String, captures: [String: String]) {
    self.resolverID = resolverID
    self.address = address
    self.shortID = shortID
    self.captures = captures
  }

  public var url: URL? { URL(string: address) }

  /// Two addresses are the same ticket when the same resolver gives them the same identifier:
  /// `…/issues/42` and `…/issues/42#issuecomment-1`.
  public func isSameTicket(as other: TicketRecognition) -> Bool {
    resolverID == other.resolverID && shortID == other.shortID
  }
}

/// The resolvers in use, in the order they are tried: the first that recognises an address wins.
public struct TicketResolverSet: Sendable {
  public let resolvers: [CompiledTicketResolver]

  /// The enabled resolvers that are valid. An invalid one is left out rather than blocking the
  /// others.
  public init(_ resolvers: [TicketResolver]) {
    self.resolvers = resolvers.filter(\.isEnabled).compactMap(CompiledTicketResolver.init)
  }

  public var isEmpty: Bool { resolvers.isEmpty }

  public func resolver(id: UUID) -> CompiledTicketResolver? {
    resolvers.first { $0.resolver.id == id }
  }

  public func recognize(_ address: String) -> TicketRecognition? {
    for resolver in resolvers {
      if let recognition = resolver.recognize(address) { return recognition }
    }
    return nil
  }

  /// Whether `url` is the page of `ticket`: the same resolver recognises it, as the same ticket.
  /// A sign-in page, or a redirection to another ticket, is not.
  public func isPage(_ url: URL, of ticket: TicketRecognition) -> Bool {
    guard let resolver = resolver(id: ticket.resolverID),
      let recognized = resolver.recognize(url.absoluteString)
    else { return false }
    return recognized.shortID == ticket.shortID
  }

  /// The tickets these texts name, in the order they first appear, each once.
  public func tickets(in texts: [String], limit: Int = TicketLinkExtractor.ticketLimit)
    -> [TicketRecognition]
  {
    var found: [TicketRecognition] = []
    for address in TicketLinkExtractor.addresses(in: texts) {
      guard found.count < limit, let ticket = recognize(address),
        !found.contains(where: { $0.isSameTicket(as: ticket) })
      else { continue }
      found.append(ticket)
    }
    return found
  }
}

/// Finds the web addresses in what the user typed.
public enum TicketLinkExtractor {
  /// Addresses looked at: a prompt that pastes a log must not open fifty pages.
  public static let addressLimit = 20
  public static let ticketLimit = 5
  public static let addressLengthLimit = 2048

  /// The `http(s)` addresses of `texts`, in order, without the punctuation that ends a sentence
  /// around them. The same address twice is given once.
  public static func addresses(in texts: [String]) -> [String] {
    var found: [String] = []
    for text in texts {
      for candidate in candidates(in: text) {
        guard found.count < addressLimit else { return found }
        if !found.contains(candidate) { found.append(candidate) }
      }
    }
    return found
  }

  private static let expression = try! NSRegularExpression(
    pattern: #"https?://[^\s<>"'`]+"#, options: [.caseInsensitive])

  private static func candidates(in text: String) -> [String] {
    let whole = NSRange(location: 0, length: (text as NSString).length)
    return expression.matches(in: text, range: whole).compactMap { match in
      let raw = (text as NSString).substring(with: match.range)
      let trimmed = trimmed(raw)
      guard trimmed.count <= addressLengthLimit, URL(string: trimmed)?.host?.isEmpty == false
      else { return nil }
      return trimmed
    }
  }

  /// `(voir https://…/42).` gives `https://…/42`; `https://…/wiki/A_(b)` keeps its parenthesis.
  static func trimmed(_ address: String) -> String {
    var address = Substring(address)
    while let last = address.last {
      if ".,;:!?*_".contains(last) {
        address.removeLast()
        continue
      }
      let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{", "»": "«"]
      if let opening = pairs[last] {
        let opened = address.filter { $0 == opening }.count
        let closed = address.filter { $0 == last }.count
        if closed > opened {
          address.removeLast()
          continue
        }
      }
      break
    }
    return String(address)
  }
}

/// A title as it is kept: on one line, without control characters, of a bounded length.
public enum TicketTitleText {
  public static let lengthLimit = 200

  public static func normalized(_ text: String) -> String {
    let scalars = text.unicodeScalars.map { scalar -> Character in
      CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
        ? " " : Character(scalar)
    }
    return String(scalars)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  public static func bounded(_ text: String) -> String {
    guard text.count > lengthLimit else { return text }
    return String(text.prefix(lengthLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }
}

/// The line written in the notes: `[{id}] {title} — {url}`.
public struct TicketLineFormat: Hashable, Codable, Sendable {
  public static let standard = TicketLineFormat("[{id}] {title} — {url}")
  public static let placeholders: Set<String> = ["id", "title", "url"]

  public var template: String

  public init(_ template: String) {
    self.template = template
  }

  /// A format is usable when it says the title and names nothing else than the three values.
  public var isValid: Bool {
    let names = TicketResolverSyntax.placeholders(in: template)
    return names.contains("title") && names.allSatisfy(Self.placeholders.contains)
  }

  /// The line, on one line whatever the format holds.
  public func line(id: String, title: String, url: String) -> String {
    let format = isValid ? self : .standard
    let filled = TicketResolverSyntax.fill(
      format.template, with: ["id": id, "title": title, "url": url])
    return TicketTitleText.normalized(filled)
  }
}

/// The small syntax resolvers and formats share: `{name}`, and the named captures of a pattern.
public enum TicketResolverSyntax {
  private static let placeholder = try! NSRegularExpression(
    pattern: #"\{([A-Za-z][A-Za-z0-9_]*)\}"#)
  private static let capture = try! NSRegularExpression(pattern: #"\(\?<([A-Za-z][A-Za-z0-9]*)>"#)

  public static func placeholders(in template: String) -> [String] {
    names(placeholder, in: template)
  }

  public static func captureNames(in pattern: String) -> [String] {
    names(capture, in: pattern)
  }

  /// `template` with each `{name}` replaced by its value. A name without one becomes empty.
  public static func fill(_ template: String, with values: [String: String]) -> String {
    let text = template as NSString
    var result = ""
    var cursor = 0
    for match in placeholder.matches(in: template, range: NSRange(location: 0, length: text.length))
    {
      result += text.substring(
        with: NSRange(location: cursor, length: match.range.location - cursor))
      result += values[text.substring(with: match.range(at: 1))] ?? ""
      cursor = NSMaxRange(match.range)
    }
    result += text.substring(from: cursor)
    return result.trimmingCharacters(in: .whitespaces)
  }

  /// The address with its scheme and host in lower case, as they mean; `nil` for what is not an
  /// `http(s)` address.
  static func normalized(_ address: String) -> String? {
    guard var components = URLComponents(string: address),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty
    else { return nil }
    components.scheme = scheme
    components.host = host.lowercased()
    return components.string
  }

  private static func names(_ expression: NSRegularExpression, in text: String) -> [String] {
    var seen: [String] = []
    let string = text as NSString
    for match in expression.matches(in: text, range: NSRange(location: 0, length: string.length)) {
      let name = string.substring(with: match.range(at: 1))
      if !seen.contains(name) { seen.append(name) }
    }
    return seen
  }
}
