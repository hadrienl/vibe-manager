import Foundation
import VibeDomain

/// What a report covers: one batch, or every batch of a period.
public enum ArchiveReportPeriod: Hashable, Sendable {
  case today
  case yesterday
  case last7Days
  case thisMonth
  /// From the first day to the last, both included.
  case days(from: Date, to: Date)

  /// The interval it stands for, in the Mac's calendar.
  public func interval(now: Date, calendar: Calendar) -> DateInterval {
    let today = calendar.startOfDay(for: now)
    func day(_ offset: Int, from start: Date = today) -> Date {
      calendar.date(byAdding: .day, value: offset, to: start) ?? start
    }
    switch self {
    case .today: return DateInterval(start: today, end: day(1))
    case .yesterday: return DateInterval(start: day(-1), end: today)
    case .last7Days: return DateInterval(start: day(-6), end: day(1))
    case .thisMonth:
      let start = calendar.dateInterval(of: .month, for: now)?.start ?? today
      return DateInterval(start: start, end: day(1))
    case .days(let from, let to):
      let start = calendar.startOfDay(for: min(from, to))
      return DateInterval(start: start, end: day(1, from: calendar.startOfDay(for: max(from, to))))
    }
  }
}

/// A report: the sessions of one or several batches, project by project, with their totals (#408).
/// Built from the batches alone, without an agent.
public struct ArchiveReport: Hashable, Sendable {
  /// One session in the report.
  public struct Session: Identifiable, Hashable, Sendable {
    public var snapshot: ArchivedSessionSnapshot
    /// The journal's sentences shown: those of the period, or all of them for one batch.
    public var entries: [JournalEntry]
    /// Sentences written before the period, folded under “and N older entries”.
    public var olderEntryCount: Int
    /// When the user took it out of the archive since, if they did.
    public var unarchivedAt: Date?
    /// The batch it came with.
    public var batchID: UUID

    public var id: SessionID { snapshot.sessionID }
  }

  public struct Project: Identifiable, Hashable, Sendable {
    /// `nil` for the sessions outside any group.
    public var name: String?
    public var sessions: [Session]

    public var id: String { name ?? "" }
  }

  public struct Totals: Hashable, Sendable {
    public var sessions = 0
    public var pullRequestsCreated = 0
    public var ticketsTouched = 0
    public var branches = 0
    public var runningTime: TimeInterval = 0

    public init() {
      // Everything at zero.
    }
  }

  public var batches: [ArchiveBatch]
  public var projects: [Project]
  public var totals: Totals
  /// The interval of a period's report; `nil` for one batch.
  public var interval: DateInterval?

  /// One batch: every sentence of its sessions.
  public init(batch: ArchiveBatch, sessions current: [WorkSession] = []) {
    self.init(batches: [batch], interval: nil, current: current)
  }

  /// Every batch archived within `interval`. A session archived twice in it is reported once, as
  /// it stood the last time.
  public init(batches: [ArchiveBatch], interval: DateInterval, sessions current: [WorkSession] = [])
  {
    self.init(
      batches: batches.filter { interval.contains($0.date) && $0.date < interval.end },
      interval: interval, current: current)
  }

  private init(batches: [ArchiveBatch], interval: DateInterval?, current: [WorkSession]) {
    let batches = batches.sorted { $0.date < $1.date }
    self.batches = batches
    self.interval = interval
    var latest: [SessionID: Session] = [:]
    var order: [SessionID] = []
    let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for batch in batches {
      for snapshot in batch.sessions {
        let texts = snapshot.entries.filter { !$0.text.isEmpty }
        let shown = interval.map { interval in texts.filter { $0.at >= interval.start } } ?? texts
        let session = Session(
          snapshot: snapshot, entries: shown, olderEntryCount: texts.count - shown.count,
          unarchivedAt: byID[snapshot.sessionID].flatMap {
            Self.unarchivedAt($0, after: snapshot.archivedAt)
          },
          batchID: batch.id)
        if latest[snapshot.sessionID] == nil { order.append(snapshot.sessionID) }
        latest[snapshot.sessionID] = session
      }
    }
    let sessions = order.compactMap { latest[$0] }
    var groups: [String?: [Session]] = [:]
    for session in sessions { groups[session.snapshot.project, default: []].append(session) }
    projects = groups.map { Project(name: $0.key, sessions: $0.value) }
      .sorted { lhs, rhs in
        switch (lhs.name, rhs.name) {
        case (nil, _): false
        case (_, nil): true
        case (let left?, let right?): left.localizedStandardCompare(right) == .orderedAscending
        }
      }
    totals = Self.totals(of: sessions.map(\.snapshot))
  }

  public var isEmpty: Bool { projects.isEmpty }

  /// When a session left the archive after `date`, if it did.
  public static func unarchivedAt(_ session: WorkSession, after date: Date) -> Date? {
    session.statusHistory.entries.first {
      $0.from == .archived && $0.date >= date
    }?.date
  }

  static func totals(of sessions: [ArchivedSessionSnapshot]) -> Totals {
    var totals = Totals()
    totals.sessions = sessions.count
    var pullRequests = Set<String>()
    var tickets = Set<String>()
    var branches = Set<String>()
    for session in sessions {
      for resource in session.workedResources {
        switch resource.kind {
        case .pullRequest where resource.involvement == .created: pullRequests.insert(resource.key)
        case .issue: tickets.insert(resource.key)
        case .branch: branches.insert(resource.key)
        default: break
        }
      }
      totals.runningTime += session.runningTime ?? 0
    }
    totals.pullRequestsCreated = pullRequests.count
    totals.ticketsTouched = tickets.count
    totals.branches = branches.count
    return totals
  }
}
