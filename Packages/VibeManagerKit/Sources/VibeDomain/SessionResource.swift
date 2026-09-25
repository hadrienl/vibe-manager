import Foundation

/// A ticket, a pull or merge request, a branch or a worktree a session used (#36).
///
/// Read from what the agent's transcript says, never generated: a resource is only ever listed
/// because a URL, a `gh`, `glab` or `git` command, or a working folder named it.
public struct SessionResource: Hashable, Codable, Sendable, Identifiable {
  public enum Kind: String, Hashable, Codable, Sendable, CaseIterable {
    case issue
    case pullRequest
    case branch
    case worktree
  }

  /// How far the session went with it. It only ever rises: a pull request created and then
  /// looked at is still the one the session created.
  public enum Involvement: Int, Hashable, Codable, Sendable, Comparable {
    case viewed
    case changed
    case created

    public static func < (lhs: Involvement, rhs: Involvement) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }

  /// What a click opens.
  public enum Target: Hashable, Codable, Sendable {
    /// A page of a forge.
    case web(URL)
    /// A folder on this Mac.
    case folder(String)
    /// A branch of a repository: its page on the forge when its remote is one, its repository
    /// otherwise.
    case branch(repositoryPath: String, webURL: URL?)
  }

  /// The identity two sightings are compared by, never a raw URL: `/issues/62` and `/pull/62` of
  /// the same GitHub repository are one resource, `http` and `https` too.
  public let key: String
  public var kind: Kind
  /// "#36", "!1315", "feat/36-journal", "agent-3".
  public var label: String
  /// Where it belongs: "hadrienl/vibe-manager", "group/sub/project", a repository's name.
  public var context: String?
  public var target: Target
  public var involvement: Involvement
  public var firstSeenAt: Date
  public var lastSeenAt: Date

  public init(
    key: String,
    kind: Kind,
    label: String,
    context: String?,
    target: Target,
    involvement: Involvement,
    firstSeenAt: Date,
    lastSeenAt: Date? = nil
  ) {
    self.key = key
    self.kind = kind
    self.label = label
    self.context = context
    self.target = target
    self.involvement = involvement
    self.firstSeenAt = firstSeenAt
    self.lastSeenAt = lastSeenAt ?? firstSeenAt
  }

  public var id: String { key }

  /// The same resource seen again. It keeps when it was first seen, and takes the most precise of
  /// the two descriptions: GitHub numbers issues and pull requests together, and a number first
  /// seen as `/issues/62` that turns out to be `/pull/62` is a pull request.
  public func merging(_ other: SessionResource) -> SessionResource {
    var merged = self
    if kind == .issue, other.kind == .pullRequest {
      merged.kind = .pullRequest
      merged.label = other.label
      merged.target = other.target
    }
    if merged.context == nil { merged.context = other.context }
    if case .branch(let path, nil) = merged.target, case .branch(_, let url?) = other.target {
      merged.target = .branch(repositoryPath: path, webURL: url)
    }
    merged.involvement = max(involvement, other.involvement)
    merged.firstSeenAt = min(firstSeenAt, other.firstSeenAt)
    merged.lastSeenAt = max(lastSeenAt, other.lastSeenAt)
    return merged
  }
}
