import Foundation

/// A time a rule is due, claimed by this copy of the application: it runs it now.
public struct ArchiveDueRun: Hashable, Sendable {
  public let ruleID: UUID
  public let rule: ArchiveRule
  /// The time it stands for: the last one passed, when several were missed.
  public let due: Date
  /// Run late: the Mac slept, or the application was closed, when it was due.
  public let isCatchUp: Bool
  public let isTrial: Bool
}

/// Says when rules are due, and claims them (#405). The time is the clock's, the calendar and the
/// time zone the Mac's: the test bench runs the same code with a clock of its own.
public struct ArchiveRuleScheduler: Sendable {
  /// A run within this of its time is on time; later, it is a catch-up.
  public static let lateness: TimeInterval = 120
  /// A rule that runs `continuously` runs at most this often.
  public static let continuousThrottle: TimeInterval = 60

  public enum Decision: Hashable, Sendable {
    case none
    /// Due at `due`, run now.
    case run(due: Date, isCatchUp: Bool)
    /// Missed, and the rule does not catch up: marked handled, and nothing runs.
    case pass(due: Date)
  }

  private let store: any ArchiveRuleStore
  private let clock: any SessionClock
  private let calendar: @Sendable () -> Calendar

  public init(
    store: any ArchiveRuleStore, clock: any SessionClock = SystemSessionClock(),
    calendar: @escaping @Sendable () -> Calendar = { .autoupdatingCurrent }
  ) {
    self.store = store
    self.clock = clock
    self.calendar = calendar
  }

  /// What a rule does at `now`, from where it last stood.
  public static func decision(
    for stored: StoredArchiveRule, now: Date, calendar: Calendar
  ) -> Decision {
    guard stored.runs, let rule = stored.rule else { return .none }
    // Turned on again after a pause: the times it was off are not caught up.
    let anchor = max(stored.lastHandled ?? stored.activatedAt, stored.activatedAt)
    if rule.schedule == .continuously {
      guard now.timeIntervalSince(stored.lastHandled ?? .distantPast) >= continuousThrottle else {
        return .none
      }
      return .run(due: now, isCatchUp: false)
    }
    guard
      let latest = rule.schedule.latestOccurrence(
        atOrBefore: now, since: anchor, calendar: calendar, activatedAt: stored.activatedAt)
    else { return .none }
    let late = now.timeIntervalSince(latest) > lateness
    if late, !rule.catchesUp { return .pass(due: latest) }
    return .run(due: latest, isCatchUp: late)
  }

  /// When something next needs looking at: the earliest next time of a rule that runs, and every
  /// `continuousInterval` while one runs continuously.
  public static func nextWake(for set: ArchiveRuleSet, after now: Date, calendar: Calendar)
    -> Date?
  {
    var dates: [Date] = []
    for stored in set.rules where stored.runs {
      guard let rule = stored.rule else { continue }
      if rule.schedule == .continuously {
        dates.append(now.addingTimeInterval(ArchiveSchedule.continuousInterval))
        continue
      }
      let anchor = max(stored.lastHandled ?? stored.activatedAt, stored.activatedAt, now)
      if let next = rule.schedule.nextOccurrence(
        after: anchor, calendar: calendar, activatedAt: stored.activatedAt)
      {
        dates.append(next)
      }
    }
    return dates.min()
  }

  /// Claims every rule due now, in one change of the store: a time another copy claimed first is
  /// not run here.
  public func claimDueRuns() async throws -> [ArchiveDueRun] {
    let now = clock.now()
    let calendar = calendar()
    let claimed = ClaimedRuns()
    try await store.update { set in
      for index in set.rules.indices {
        let stored = set.rules[index]
        switch Self.decision(for: stored, now: now, calendar: calendar) {
        case .none:
          continue
        case .pass(let due):
          set.rules[index].lastHandled = due
        case .run(let due, let isCatchUp):
          guard let rule = stored.rule else { continue }
          set.rules[index].lastHandled = due
          claimed.append(
            ArchiveDueRun(
              ruleID: stored.id, rule: rule, due: due, isCatchUp: isCatchUp,
              isTrial: stored.state == .trial))
        }
      }
    }
    return claimed.runs
  }

  /// Writes what a run did on its rule's line.
  public func record(_ result: ArchiveRunResult, for id: UUID) async throws {
    try await store.update { set in
      guard let index = set.rules.firstIndex(where: { $0.id == id }) else { return }
      set.rules[index].lastRun = result
    }
  }
}

/// The runs claimed inside the store's change, which runs at once and on one thread.
private final class ClaimedRuns: @unchecked Sendable {
  private let lock = NSLock()
  private var value: [ArchiveDueRun] = []

  var runs: [ArchiveDueRun] { lock.withLock { value } }

  func append(_ run: ArchiveDueRun) {
    lock.withLock { value.append(run) }
  }
}
