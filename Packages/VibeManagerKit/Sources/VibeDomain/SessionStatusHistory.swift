import Foundation

/// One move of a session from a status to another, and who or what made it (#406).
public struct SessionStatusChange: Hashable, Codable, Sendable {
  /// Why a session changed status. Given by the use case that makes the change, never guessed.
  public enum Cause: Hashable, Codable, Sendable {
    /// The session was created, in the column it starts in.
    case created
    /// A gesture of the user: a swipe, a menu, a drag, the keyboard, a batch.
    case user
    /// Starting or restarting the session put it back In Progress.
    case launch
    /// A coordinator moved one of its children (#352). Its identifier, not its name, which can
    /// change.
    case coordinator(SessionID)
    /// The user unarchived the session.
    case unarchive
    /// ⌘Z took back a move, an archive, or a batch archive (#242).
    case undo
    /// An automatic archive rule archived it (#405). The rule's name is kept as it was then: the
    /// rule may be renamed or removed since.
    case rule(id: UUID, name: String)
    /// Rebuilt from the dates the store knew, at the migration to the history or after a history
    /// that did not hold.
    case reconstructed
  }

  public let date: Date
  /// `nil` for the entry that creates the session.
  public let from: SessionTaskStatus?
  public let to: SessionTaskStatus
  public let cause: Cause

  public init(date: Date, from: SessionTaskStatus?, to: SessionTaskStatus, cause: Cause) {
    self.date = date.storageRounded
    self.from = from
    self.to = to
    self.cause = cause
  }
}

/// Every status a session went through, oldest first (#406).
///
/// It only grows: ⌘Z adds an entry, it does not remove one. The oldest entries go past
/// `limit`, except the one that creates the session.
public struct SessionStatusHistory: Hashable, Codable, Sendable {
  /// Enough for years of a session moved every day; a session's history costs a few bytes an entry.
  public static let limit = 500

  public private(set) var entries: [SessionStatusChange]

  /// A history as it was read. `isConsistent(with:)` says whether it may be kept.
  public init(entries: [SessionStatusChange]) {
    self.entries = entries
  }

  /// The history of a session created now, in `status`.
  public static func created(in status: SessionTaskStatus, at date: Date) -> SessionStatusHistory
  {
    SessionStatusHistory(entries: [
      SessionStatusChange(date: date, from: nil, to: status, cause: .created)
    ])
  }

  /// What the store knew before the history existed, laid out as one: created To Do, In Progress
  /// when it was first started, then where it stands now. Every entry says it was rebuilt: the
  /// store kept only the last date of each step, there is nothing better to rebuild from.
  public static func reconstructed(
    lifecycle: SessionLifecycle, taskStatus: SessionTaskStatus
  ) -> SessionStatusHistory {
    var entries = [
      SessionStatusChange(
        date: lifecycle.createdAt, from: nil, to: .todo, cause: .reconstructed)
    ]
    func add(_ status: SessionTaskStatus, at date: Date) {
      guard let last = entries.last, last.to != status else { return }
      entries.append(
        SessionStatusChange(
          date: max(date, last.date), from: last.to, to: status, cause: .reconstructed))
    }
    if let startedAt = lifecycle.startedAt { add(.doing, at: startedAt) }
    if taskStatus == .archived {
      // Archived from Done: unarchiving brings it back there.
      add(.done, at: lifecycle.closedAt ?? lifecycle.updatedAt)
      add(.archived, at: lifecycle.archivedAt ?? lifecycle.updatedAt)
    } else {
      add(taskStatus, at: lifecycle.updatedAt)
    }
    return SessionStatusHistory(entries: entries)
  }

  /// Whether this history can be the one of a session that stands in `status` now: in the order
  /// of the dates, each entry leaving the status the one before arrived at, the first one
  /// creating the session, and the last one arriving where the session is.
  ///
  /// The link right after the first entry may be broken in a full history: that is where `limit`
  /// cut.
  public func isConsistent(with status: SessionTaskStatus) -> Bool {
    guard let first = entries.first, first.from == nil, entries.last?.to == status else {
      return false
    }
    for index in entries.indices.dropFirst() {
      let previous = entries[index - 1]
      let entry = entries[index]
      guard let from = entry.from, from != entry.to, entry.date >= previous.date else {
        return false
      }
      guard from == previous.to || (index == 1 && entries.count == Self.limit) else {
        return false
      }
    }
    return true
  }

  mutating func append(
    from: SessionTaskStatus, to: SessionTaskStatus, at date: Date, cause: SessionStatusChange.Cause
  ) {
    let date = max(date, entries.last?.date ?? date)
    entries.append(SessionStatusChange(date: date, from: from, to: to, cause: cause))
    if entries.count > Self.limit {
      entries.removeSubrange(1...(entries.count - Self.limit))
    }
  }

  // MARK: - Reading it

  /// The last entry, the one that brought the session where it is.
  public var lastEntry: SessionStatusChange? {
    entries.last
  }

  /// When the session last arrived where it stands: for a finished one, when it was done last —
  /// a session reopened and finished again counts from its last end.
  public var enteredCurrentStatusAt: Date? {
    entries.last?.date
  }

  /// Why the session last arrived where it stands.
  public var lastEntryCause: SessionStatusChange.Cause? {
    entries.last?.cause
  }

  /// The first time the session arrived in `status`, if it ever did.
  public func firstEntry(into status: SessionTaskStatus) -> Date? {
    entries.first { $0.to == status }?.date
  }

  /// How many times the session left Done for another column. Archiving it is not reopening it.
  public var reopenCount: Int {
    entries.filter { $0.from == .done && SessionTaskStatus.columns.contains($0.to) }.count
  }

  /// How long the session has spent in `status`, up to `now` for the status it is in.
  public func timeSpent(in status: SessionTaskStatus, until now: Date) -> TimeInterval {
    var total: TimeInterval = 0
    for (index, entry) in entries.enumerated() where entry.to == status {
      let end = index + 1 < entries.count ? entries[index + 1].date : max(now, entry.date)
      total += end.timeIntervalSince(entry.date)
    }
    return total
  }
}
