import Foundation
import VibeDomain

/// A session made up for the test bench (#405): what a real one is, and what happens to it over
/// time. Never written to the store, never sent to an agent, never archived for real.
public struct BenchSession: Identifiable, Hashable, Sendable {
  public let id: SessionID
  public var name: String
  public var colorHex: String
  public var symbolName: String
  public var showsProjectIcon: Bool
  public var project: String?
  public var folder: String?
  public var agent: String
  public var model: String?
  public var ticket: URL?
  public var branch: String?
  /// Whether its folder has changes, until `cleanAt` if it is given.
  public var isDirty: Bool
  public var cleanAt: Date?
  public var coordination: SessionCoordination?
  public var createdAt: Date
  /// Its agent, or a command, runs until then.
  public var runningUntil: Date?
  /// Every move of its status, past and to come, oldest first; the first one creates it.
  public var history: [SessionStatusChange]

  public init(
    id: SessionID = SessionID(), name: String, colorHex: String = "#5E5CE6",
    symbolName: String = "terminal", showsProjectIcon: Bool = false, project: String? = nil,
    folder: String? = nil, agent: String = "claude", model: String? = nil, ticket: URL? = nil,
    branch: String? = "main", isDirty: Bool = false, cleanAt: Date? = nil,
    coordination: SessionCoordination? = nil, createdAt: Date, runningUntil: Date? = nil,
    history: [SessionStatusChange]
  ) {
    self.id = id
    self.name = name
    self.colorHex = colorHex
    self.symbolName = symbolName
    self.showsProjectIcon = showsProjectIcon
    self.project = project
    self.folder = folder
    self.agent = agent
    self.model = model
    self.ticket = ticket
    self.branch = branch
    self.isDirty = isDirty
    self.cleanAt = cleanAt
    self.coordination = coordination
    self.createdAt = createdAt
    self.runningUntil = runningUntil
    self.history = history
  }

  /// A session created at `createdAt` and done at `doneAt`, in its folder of `project`.
  public static func done(
    _ name: String, at doneAt: Date, createdAt: Date? = nil,
    configure: (inout BenchSession) -> Void = { _ in }
  ) -> BenchSession {
    let created = min(createdAt ?? doneAt.addingTimeInterval(-86_400), doneAt)
    var session = BenchSession(
      name: name, createdAt: created,
      history: [
        SessionStatusChange(date: created, from: nil, to: .todo, cause: .created),
        SessionStatusChange(date: created, from: .todo, to: .doing, cause: .launch),
        SessionStatusChange(date: doneAt, from: .doing, to: .done, cause: .user),
      ])
    configure(&session)
    return session
  }

  /// Adds a move at `date`, from where it stands then.
  public mutating func move(
    to status: SessionTaskStatus, at date: Date, cause: SessionStatusChange.Cause = .user
  ) {
    let before = history.last { $0.date <= date }?.to ?? .todo
    guard before != status else { return }
    let index = history.firstIndex { $0.date > date } ?? history.endIndex
    history.insert(SessionStatusChange(date: date, from: before, to: status, cause: cause), at: index)
    // The move that followed now leaves from here.
    if index + 1 < history.count {
      let next = history[index + 1]
      history[index + 1] = SessionStatusChange(
        date: next.date, from: status, to: next.to, cause: next.cause)
      if next.to == status { history.remove(at: index + 1) }
    }
  }

  /// Where it stands at `date`, before the bench archives anything.
  public func status(at date: Date) -> SessionTaskStatus {
    history.last { $0.date <= date }?.to ?? .todo
  }

  /// The session as the rules see it at `date`, its history cut there.
  public func candidate(at date: Date) -> ArchiveCandidate {
    let entries = history.filter { $0.date <= date }
    let status = entries.last?.to ?? .todo
    let lifecycle: SessionStatus = status == .archived ? .archived : .closed
    let last = entries.last?.date ?? createdAt
    let session = WorkSession(
      id: id, name: name,
      agent: SessionAgentConfiguration(providerID: agent, modelID: model),
      appearance: SessionAppearance(
        symbolName: symbolName, colorHex: colorHex,
        iconID: showsProjectIcon ? SessionIconID(sha256: String(repeating: "0", count: 64)) : nil),
      status: lifecycle, createdAt: createdAt, updatedAt: max(last, createdAt),
      closedAt: max(last, createdAt), archivedAt: status == .archived ? max(last, createdAt) : nil,
      startedAt: createdAt,
      ticket: ticket.map { SessionTicket(url: $0, source: .manual) },
      taskStatus: status, coordination: coordination,
      statusHistory: entries.isEmpty ? nil : SessionStatusHistory(entries: entries))
    return ArchiveCandidate(
      session: session, project: project, folder: folder, branch: branch,
      isDirty: isDirty && (cleanAt.map { date < $0 } ?? true),
      isRunning: runningUntil.map { date < $0 } ?? false)
  }

  /// The dates something happens to it on its own.
  var eventDates: [Date] {
    history.map(\.date) + [runningUntil, cleanAt].compactMap { $0 }
  }
}

/// A period the bench says the Mac is off: nothing runs, and a missed time is caught up when it
/// comes back.
public struct BenchOffPeriod: Hashable, Sendable, Identifiable {
  public let id: UUID
  public var interval: DateInterval

  public init(id: UUID = UUID(), interval: DateInterval) {
    self.id = id
    self.interval = interval
  }
}

extension ArchiveCondition {
  /// The durations it compares with: when they are reached, its answer may change.
  var durations: [ArchiveDuration] {
    switch self {
    case .test(let test):
      if case .duration(let duration) = test.value { return [duration] }
      return []
    case .not(let inner): return inner.durations
    case .all(let parts), .any(let parts): return parts.flatMap(\.durations)
    }
  }
}

/// What happened over the bench's time.
public struct BenchOutcome: Hashable, Sendable {
  public struct Archival: Hashable, Sendable {
    public let date: Date
    public let ruleName: String
    public let ruleIndex: Int
  }

  public struct Skip: Hashable, Sendable {
    public let date: Date
    public let verdict: ArchiveVerdict
    public let ruleName: String
  }

  /// A time a rule was due, and what was made of it.
  public struct Run: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
      case onTime
      /// Run late, at `ranAt`, standing for the times missed.
      case catchUp(ranAt: Date)
      /// Missed and not caught up.
      case passed
      /// The Mac was off then: run later, or passed.
      case missed
    }

    public let ruleIndex: Int
    public let due: Date
    public let kind: Kind
  }

  public var archivals: [SessionID: Archival] = [:]
  public var skips: [SessionID: [Skip]] = [:]
  public var runs: [Run] = []

  public init() {}

  /// Where each session stands at `date`: archived, or still there.
  public func isArchived(_ id: SessionID, at date: Date) -> Bool {
    archivals[id].map { $0.date <= date } ?? false
  }
}

/// The bench: the rules run over made-up sessions and a span of time, with a simulated clock —
/// the same decisions and the same evaluation as the real runs (`ArchiveRuleScheduler.decision`,
/// `ArchiveRuleEvaluation.plan`), never copied.
public enum ArchiveRuleBench {
  public static func run(
    _ document: ArchiveRuleDocument, protections extra: [ArchiveProtection] = [],
    sessions: [BenchSession], from start: Date, through end: Date, calendar: Calendar,
    off: [BenchOffPeriod] = []
  ) -> BenchOutcome {
    var outcome = BenchOutcome()
    let protections = document.protections + extra
    var stored = document.rules.map { rule in
      StoredArchiveRule(
        text: ArchiveRulePrinter.text(of: rule), state: .active, sentence: "", agent: "",
        createdAt: start, activatedAt: start)
    }
    // Every moment something may happen: each time a rule is due, each event of a session, each
    // time the Mac comes back, and every quarter of an hour for a rule that runs continuously.
    var moments: Set<Date> = []
    // A rule that runs continuously looks every quarter of an hour: when a duration it reads is
    // reached, it acts at the next quarter.
    let grid = ArchiveSchedule.continuousInterval
    func onGrid(_ date: Date) -> Date {
      start.addingTimeInterval((date.timeIntervalSince(start) / grid).rounded(.up) * grid)
    }
    for rule in document.rules {
      if rule.schedule == .continuously {
        let durations = ([rule.condition].compactMap { $0 } + protections.map(\.condition))
          .flatMap(\.durations)
        moments.insert(start)
        for session in sessions {
          for date in session.eventDates {
            for duration in durations {
              let reached = onGrid(date.addingTimeInterval(duration.seconds))
              if reached >= start, reached <= end { moments.insert(reached) }
            }
          }
        }
      } else {
        for due in rule.schedule.occurrences(
          from: start, through: end, calendar: calendar, activatedAt: start)
        {
          moments.insert(due)
        }
      }
    }
    for session in sessions {
      for date in session.eventDates where date >= start && date <= end {
        moments.insert(date)
        // A rule running continuously looks again once the change is through.
        moments.insert(date.addingTimeInterval(ArchiveRuleScheduler.continuousThrottle))
      }
    }
    for period in off where period.interval.end <= end {
      moments.insert(period.interval.end)
    }
    let isOff: (Date) -> Bool = { date in
      off.contains { $0.interval.start <= date && date < $0.interval.end }
    }
    for (index, rule) in document.rules.enumerated() where rule.schedule != .continuously {
      for due in rule.schedule.occurrences(
        from: start, through: end, calendar: calendar, activatedAt: start) where isOff(due)
      {
        outcome.runs.append(BenchOutcome.Run(ruleIndex: index, due: due, kind: .missed))
      }
    }

    for now in moments.sorted() where !isOff(now) {
      let candidates = sessions.filter { !outcome.isArchived($0.id, at: now) }
        .map { $0.candidate(at: now) }
      var remaining = candidates
      for index in stored.indices {
        let rule = document.rules[index]
        switch ArchiveRuleScheduler.decision(for: stored[index], now: now, calendar: calendar) {
        case .none:
          continue
        case .pass(let due):
          stored[index].lastHandled = due
          outcome.runs.append(BenchOutcome.Run(ruleIndex: index, due: due, kind: .passed))
        case .run(let due, let isCatchUp):
          stored[index].lastHandled = due
          if rule.schedule != .continuously {
            outcome.runs.append(
              BenchOutcome.Run(
                ruleIndex: index, due: due, kind: isCatchUp ? .catchUp(ranAt: now) : .onTime))
          }
          let plan = ArchiveRuleEvaluation.plan(
            rule: rule, protections: protections, candidates: remaining, now: now,
            calendar: calendar)
          for id in plan.archived {
            outcome.archivals[id] = BenchOutcome.Archival(
              date: now, ruleName: rule.name, ruleIndex: index)
          }
          for (id, verdict) in plan.skipped {
            outcome.skips[id, default: []].append(
              BenchOutcome.Skip(date: now, verdict: verdict, ruleName: rule.name))
          }
          let gone = Set(plan.archived)
          remaining.removeAll { gone.contains($0.id) }
        }
      }
    }
    return outcome
  }

  /// Why a session the rules never archived stays: what the first rule says of it at `date`.
  public static func neverReason(
    of session: BenchSession, document: ArchiveRuleDocument, at date: Date, calendar: Calendar
  ) -> ArchiveVerdict? {
    let candidate = session.candidate(at: date)
    var reasons: [ArchiveVerdict] = []
    for rule in document.rules {
      reasons.append(
        ArchiveRuleEvaluation.verdict(
          of: candidate, rule: rule, protections: document.protections, now: date,
          calendar: calendar))
    }
    // A protection or a column says it best; otherwise, what the first rule asks.
    return reasons.first { if case .protected = $0 { true } else { false } }
      ?? reasons.first { $0 == .notDone } ?? reasons.first
  }
}
