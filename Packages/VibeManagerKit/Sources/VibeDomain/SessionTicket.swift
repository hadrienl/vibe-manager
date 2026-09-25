import Foundation

/// The ticket a session works on, when someone said which one (#69).
///
/// Only what a person decided is stored: typed in, or brought by a template. A ticket deduced from
/// the branch is computed each time from the branch the repository is on now, so it follows a
/// checkout and is never written anywhere.
public struct SessionTicket: Hashable, Codable, Sendable {
  public enum Source: String, Codable, Sendable {
    case manual
    case template
  }

  /// `nil` when the ticket was removed on purpose: the branch must not bring it back.
  public var url: URL?
  public var source: Source

  public init(url: URL?, source: Source) {
    self.url = url
    self.source = source
  }

  /// "No ticket, and do not deduce one."
  public static let removed = SessionTicket(url: nil, source: .manual)
}

/// Which forge a repository lives on, as far as its web addresses are concerned.
public enum CodeForge: String, Hashable, Codable, Sendable {
  case github
  case gitlab

  /// The forge a host is taken for. `github.com` and `gitlab.com`, and any host whose name says
  /// `gitlab` — a company's own instance. Any other host is unknown, and nothing is deduced there.
  public static func of(host: String) -> CodeForge? {
    let host = host.lowercased()
    if host == "github.com" || host == "www.github.com" { return .github }
    if host.split(separator: ".").contains(where: { $0.contains("gitlab") }) { return .gitlab }
    return nil
  }
}

/// A repository's home on its forge: `https://github.com/owner/repo`.
public struct RepositoryWebAddress: Hashable, Sendable {
  public let forge: CodeForge
  public let host: String
  /// `owner/repo`, or `group/subgroup/project`: never empty, never with a leading slash.
  public let path: String

  public init(forge: CodeForge, host: String, path: String) {
    self.forge = forge
    self.host = host.lowercased()
    self.path = path
  }

  public var url: URL {
    URL(string: "https://\(host)/\(path)")!
  }

  public func issueURL(number: Int) -> URL {
    switch forge {
    case .github: return URL(string: "https://\(host)/\(path)/issues/\(number)")!
    case .gitlab: return URL(string: "https://\(host)/\(path)/-/issues/\(number)")!
    }
  }

  /// The web address of a Git remote: `git@github.com:o/r.git`, `https://github.com/o/r`,
  /// `ssh://git@gitlab.example.com:2222/g/s/p.git`. `nil` for a local path, a forge this cannot
  /// tell, or anything that is not a remote.
  public static func of(remote: String) -> RepositoryWebAddress? {
    let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    var host: String
    var path: String
    if remote.contains("://") {
      guard let components = URLComponents(string: remote),
        let scheme = components.scheme?.lowercased(),
        ["https", "http", "ssh", "git", "git+ssh"].contains(scheme),
        let parsedHost = components.host, !parsedHost.isEmpty
      else { return nil }
      host = parsedHost
      path = components.path
    } else {
      // scp-like: `[user@]host:path`. A colon after a slash is a local path, not a remote.
      guard let colon = remote.firstIndex(of: ":"),
        !remote[..<colon].contains("/")
      else { return nil }
      let authority = remote[..<colon]
      host = String(authority.split(separator: "@").last ?? "")
      path = String(remote[remote.index(after: colon)...])
    }
    path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if path.hasSuffix(".git") { path.removeLast(4) }
    guard !host.isEmpty, let forge = CodeForge.of(host: host) else { return nil }
    let segments = path.split(separator: "/", omittingEmptySubsequences: true)
    guard segments.count >= 2, !segments.contains(where: { $0 == ".." || $0 == "." }) else {
      return nil
    }
    return RepositoryWebAddress(forge: forge, host: host, path: segments.joined(separator: "/"))
  }
}

/// A ticket or a merge request on a forge, from its web address — pasted with whatever tab,
/// anchor or trailing slash the browser left on it.
public struct IssueReference: Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable {
    case issue
    case mergeRequest
  }

  public let kind: Kind
  public let number: Int
  public let repository: RepositoryWebAddress

  public init(kind: Kind, number: Int, repository: RepositoryWebAddress) {
    self.kind = kind
    self.number = number
    self.repository = repository
  }

  /// The canonical address: no anchor, no query, no tab suffix.
  public var url: URL {
    switch (repository.forge, kind) {
    case (_, .issue): return repository.issueURL(number: number)
    case (.github, .mergeRequest):
      return URL(string: "https://\(repository.host)/\(repository.path)/pull/\(number)")!
    case (.gitlab, .mergeRequest):
      return URL(
        string: "https://\(repository.host)/\(repository.path)/-/merge_requests/\(number)")!
    }
  }

  /// `#12` for a ticket, `!12` for a GitLab merge request, `#12` for a GitHub pull request.
  public var shortLabel: String {
    kind == .mergeRequest && repository.forge == .gitlab ? "!\(number)" : "#\(number)"
  }

  public static func parse(_ url: URL) -> IssueReference? {
    guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      let host = url.host, let forge = CodeForge.of(host: host)
    else { return nil }
    var segments = url.path.split(separator: "/").map(String.init)
    switch forge {
    case .github:
      // owner/repo/(issues|pull)/N[/files|/commits…]
      guard segments.count >= 4, let number = Int(segments[3]), number > 0 else { return nil }
      let kind: Kind
      switch segments[2] {
      case "issues": kind = .issue
      case "pull", "pulls": kind = .mergeRequest
      default: return nil
      }
      return IssueReference(
        kind: kind, number: number,
        repository: RepositoryWebAddress(
          forge: forge, host: host, path: segments[0...1].joined(separator: "/")))
    case .gitlab:
      // group/…/project/-/(issues|merge_requests|work_items)/N[/diffs…]
      guard let dash = segments.firstIndex(of: "-"), dash >= 2, dash + 2 < segments.count,
        let number = Int(segments[dash + 2]), number > 0
      else { return nil }
      let kind: Kind
      switch segments[dash + 1] {
      case "issues", "work_items": kind = .issue
      case "merge_requests": kind = .mergeRequest
      default: return nil
      }
      segments = Array(segments[..<dash])
      return IssueReference(
        kind: kind, number: number,
        repository: RepositoryWebAddress(
          forge: forge, host: host, path: segments.joined(separator: "/")))
    }
  }
}

/// The ticket number a branch is named after, by the conventions people actually use:
/// `feat/12-web-view`, `fix/12_crash`, `12-web-view`, `issue-12`, `gh-12`.
public enum BranchTicketInference {
  public static func issueNumber(branch: String) -> Int? {
    let branch = branch.trimmingCharacters(in: .whitespaces)
    guard !branch.isEmpty, !branch.hasPrefix("dependabot/"), !branch.hasPrefix("renovate/")
    else { return nil }
    // The last segment names the work; the ones before it are a type or an owner.
    guard let last = branch.split(separator: "/").last.map(String.init) else { return nil }
    let lowered = last.lowercased()

    for prefix in ["issue-", "issues-", "gh-", "ticket-"] where lowered.hasPrefix(prefix) {
      let rest = lowered.dropFirst(prefix.count)
      return leadingNumber(in: rest, requiringWordAfter: false)
    }
    return leadingNumber(in: Substring(lowered), requiringWordAfter: true)
  }

  /// Digits at the start, followed by the end, or by `-` / `_` and then a letter: `12-web` is a
  /// ticket, `2026-09-25-…` and `1.2` are not.
  private static func leadingNumber(in text: Substring, requiringWordAfter: Bool) -> Int? {
    let digits = text.prefix(while: \.isASCIIDigitCharacter)
    guard !digits.isEmpty, digits.count <= 7, let number = Int(digits), number > 0 else {
      return nil
    }
    let rest = text.dropFirst(digits.count)
    guard let separator = rest.first else { return requiringWordAfter ? nil : number }
    guard separator == "-" || separator == "_" else { return nil }
    guard let next = rest.dropFirst().first else { return nil }
    return next.isLetter ? number : nil
  }
}

extension Character {
  fileprivate var isASCIIDigitCharacter: Bool {
    isASCII && isNumber
  }
}

/// What a person typed where a ticket is asked for: a whole address, or `#12` / `12` against the
/// repository the session works in.
public enum TicketInput {
  public static func url(from text: String, repository: RepositoryWebAddress?) -> URL? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let number = text.hasPrefix("#") ? String(text.dropFirst()) : text
    if let value = Int(number), value > 0 {
      return repository?.issueURL(number: value)
    }
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http", url.host?.isEmpty == false
    else { return nil }
    return IssueReference.parse(url)?.url ?? url
  }
}

/// Which ticket a session shows, among what it was given and what its branch says.
public enum TicketResolution {
  public enum Origin: String, Hashable, Sendable {
    case manual
    case template
    case branch
  }

  public struct Resolved: Hashable, Sendable {
    public let url: URL
    public let origin: Origin

    public init(url: URL, origin: Origin) {
      self.url = url
      self.origin = origin
    }

    /// `#12`, or the host when the address is not a forge's ticket.
    public var label: String {
      IssueReference.parse(url)?.shortLabel ?? url.host ?? url.absoluteString
    }
  }

  /// Manual first, then the template's, then the branch's. A ticket removed on purpose hides the
  /// branch's.
  public static func resolve(
    stored: SessionTicket?,
    branch: String?,
    repository: RepositoryWebAddress?
  ) -> Resolved? {
    if let stored {
      guard let url = stored.url else { return nil }
      return Resolved(url: url, origin: stored.source == .manual ? .manual : .template)
    }
    guard let branch, let repository,
      let number = BranchTicketInference.issueNumber(branch: branch)
    else { return nil }
    return Resolved(url: repository.issueURL(number: number), origin: .branch)
  }
}
