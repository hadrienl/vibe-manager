import Foundation
import VibeDomain

/// One archive, and what it took away (#408): a run of a rule that archived something, a run on
/// trial that would have, or the day's archives by hand. Each session is kept as it stood then,
/// so that its report stays right after a rename, an unarchive, or a journal cleared.
public struct ArchiveBatch: Identifiable, Hashable, Codable, Sendable {
  public static let format = 1

  public enum Kind: Hashable, Codable, Sendable {
    /// A rule archived these sessions. Its name is kept as it was then.
    case rule(id: UUID, name: String)
    /// A rule on trial would have archived them: nothing left the list.
    case trial(id: UUID, name: String)
    /// The day's archives by hand: ⌃⌘A, the swipe, the batch. One per day.
    case manual
  }

  public var format: Int
  public let id: UUID
  public var kind: Kind
  /// When the rule ran; for the day's archives by hand, the first of them.
  public var date: Date
  public var sessions: [ArchivedSessionSnapshot]
  /// What the rule left, and why.
  public var skipped: [SkippedSession]
  /// The paragraph an agent wrote over the batch, when it was asked.
  public var synthesis: ArchiveSynthesis?

  public init(
    id: UUID = UUID(), kind: Kind, date: Date, sessions: [ArchivedSessionSnapshot] = [],
    skipped: [SkippedSession] = [], synthesis: ArchiveSynthesis? = nil
  ) {
    format = Self.format
    self.id = id
    self.kind = kind
    self.date = date
    self.sessions = sessions
    self.skipped = skipped
    self.synthesis = synthesis
  }

  public var isTrial: Bool {
    if case .trial = kind { true } else { false }
  }

  /// The rule's name, or `nil` for the archives by hand.
  public var ruleName: String? {
    switch kind {
    case .rule(_, let name), .trial(_, let name): name
    case .manual: nil
    }
  }
}

/// A session as it stood when it was archived.
public struct ArchivedSessionSnapshot: Identifiable, Hashable, Codable, Sendable {
  public let sessionID: SessionID
  public var archivedAt: Date
  public var name: String
  public var colorHex: String
  public var symbolName: String
  /// Its group, as the sidebar named it.
  public var project: String?
  public var providerID: String?
  public var createdAt: Date
  /// When it first went In Progress.
  public var startedAt: Date?
  /// When it last arrived in Done.
  public var finishedAt: Date?
  /// The time its agent ran, and the tokens it used, when the usage knew them.
  public var runningTime: TimeInterval?
  public var tokens: TokenCounts?
  /// Its journal's sentences, oldest first; an entry folding older ones away has no text.
  public var entries: [JournalEntry]
  public var resources: [SessionResource]

  public var id: SessionID { sessionID }

  public init(
    sessionID: SessionID, archivedAt: Date, name: String, colorHex: String, symbolName: String,
    project: String? = nil, providerID: String? = nil, createdAt: Date, startedAt: Date? = nil,
    finishedAt: Date? = nil, runningTime: TimeInterval? = nil, tokens: TokenCounts? = nil,
    entries: [JournalEntry] = [], resources: [SessionResource] = []
  ) {
    self.sessionID = sessionID
    self.archivedAt = archivedAt
    self.name = name
    self.colorHex = colorHex
    self.symbolName = symbolName
    self.project = project
    self.providerID = providerID
    self.createdAt = createdAt
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.runningTime = runningTime
    self.tokens = tokens
    self.entries = entries
    self.resources = resources
  }

  /// The session as it stands, with what the application knows of it besides.
  public init(
    session: WorkSession, archivedAt: Date, project: String?, journal: SessionJournal?,
    runningTime: TimeInterval?, tokens: TokenCounts?
  ) {
    self.init(
      sessionID: session.id, archivedAt: archivedAt, name: session.name,
      colorHex: session.appearance.colorHex, symbolName: session.appearance.symbolName,
      project: project, providerID: session.agent?.providerID, createdAt: session.createdAt,
      startedAt: session.statusHistory.firstEntry(into: .doing) ?? session.startedAt,
      finishedAt: session.statusHistory.entries.last(where: { $0.to == .done })?.date,
      runningTime: runningTime, tokens: tokens.flatMap { $0.isZero ? nil : $0 },
      entries: journal?.entries ?? [], resources: journal?.resources ?? [])
  }

  /// The resources it created or changed: what a report lists.
  public var workedResources: [SessionResource] {
    resources.filter { $0.involvement >= .changed }
  }
}

/// A session a rule left, and why.
public struct SkippedSession: Hashable, Codable, Sendable {
  public enum Reason: String, Hashable, Codable, Sendable {
    /// Its agent, or a command, ran.
    case running
    /// The user took it out of the archive since it was last done.
    case unarchived
    /// The rule's limit was reached.
    case overLimit
  }

  public let sessionID: SessionID
  public var name: String
  public var reason: Reason

  public init(sessionID: SessionID, name: String, reason: Reason) {
    self.sessionID = sessionID
    self.name = name
    self.reason = reason
  }
}

/// Where the agent's paragraph over a batch stands.
public enum ArchiveSynthesis: Hashable, Codable, Sendable {
  /// Asked, not answered yet.
  case pending
  case ready(text: String, providerID: String, at: Date)
  /// The agent could not write it: the report keeps its summary, and offers to try again.
  case failed(at: Date)
}
