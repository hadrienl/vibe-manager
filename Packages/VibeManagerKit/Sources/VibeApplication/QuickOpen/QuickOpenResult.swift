import Foundation
import VibeDomain

/// How well a session answers a query, best first (#37). Each rank is one rule, so a result always
/// says which rule it came from.
public enum QuickOpenRank: Int, Hashable, Sendable, Comparable {
  /// The very resource: a URL pasted, or a number with its repository.
  case exactResource = 1
  /// A number alone, a branch or a folder named in full.
  case exactName = 2
  /// Part of a branch, a worktree, a repository or a resource's label.
  case partialResource = 3
  case title = 4
  case folder = 5
  case summary = 6
  case notes = 7
  /// Nothing was typed: the sessions last worked in.
  case recent = 8

  public static func < (lhs: QuickOpenRank, rhs: QuickOpenRank) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// Why a session is listed, as the palette says it.
public enum QuickOpenReason: Hashable, Sendable {
  case resource(
    kind: SessionResource.Kind, label: String, context: String?,
    involvement: SessionResource.Involvement?)
  case title
  case folder(String)
  /// A line of the summary, cut around what matched.
  case summary(String)
  /// The notes, cut around what matched.
  case notes(String)
  case recent
}

public struct QuickOpenResult: Hashable, Sendable, Identifiable {
  public let sessionID: SessionID
  public let rank: QuickOpenRank
  public let reason: QuickOpenReason
  public let isArchived: Bool
  /// The words to set in bold in the title and the reason.
  public let highlights: [String]

  public var id: SessionID { sessionID }

  public init(
    sessionID: SessionID, rank: QuickOpenRank, reason: QuickOpenReason, isArchived: Bool,
    highlights: [String]
  ) {
    self.sessionID = sessionID
    self.rank = rank
    self.reason = reason
    self.isArchived = isArchived
    self.highlights = highlights
  }
}

/// What a search found, and what the palette needs to say about it.
public struct QuickOpenAnswer: Hashable, Sendable {
  public let query: QuickOpenQuery
  public let results: [QuickOpenResult]
  /// A ticket or request the query named precisely, found in no session: the palette says it was
  /// understood.
  public let unmatchedResource: QuickOpenReason?

  public init(
    query: QuickOpenQuery, results: [QuickOpenResult], unmatchedResource: QuickOpenReason? = nil
  ) {
    self.query = query
    self.results = results
    self.unmatchedResource = unmatchedResource
  }
}
