import Foundation

/// What kind of start an agent run was, as far as its conversation is concerned.
public enum UsageRunKind: String, Codable, CaseIterable, Sendable {
  /// A new conversation: the session's first launch, or the first run of a switched-to agent.
  case start
  /// The same conversation, taken up again by the CLI's own resume.
  case resume
  /// A new process that was handed a summary of what came before.
  case restartWithSummary
  /// A new process that was told nothing.
  case restartFresh
}

/// How a run ended, when it did.
public enum UsageRunExit: String, Codable, Sendable {
  /// The agent's process ended on its own.
  case exited
  /// The application stopped it: a close, an archive, a quit, or tracking turned off.
  case stopped
  /// The application died with it running, and the run was closed at the next launch.
  case interrupted
  /// It ended while the application was closed and the terminal host kept it (#58).
  case endedWhileAway
}

/// One run of an agent's process in a session, as the application measured it.
public struct UsageRun: Identifiable, Hashable, Sendable {
  public let id: UUID
  public let sessionID: SessionID
  public let providerID: String
  /// The model the session asked for; `nil` is the CLI's own default.
  public let modelID: String?
  public let kind: UsageRunKind
  /// Started by the restoration that follows a relaunch (#11).
  public let afterRelaunch: Bool
  /// Started by a switch of agent or model (#15).
  public let afterSwitch: Bool
  public let startedAt: Date
  public var endedAt: Date?
  public var exit: UsageRunExit?
  /// When the Mac slept while it ran. Not counted as running time.
  public var suspensions: [DateInterval]
  /// When the application quit and left it running in the terminal host.
  public var detachedAt: Date?

  public init(
    id: UUID = UUID(),
    sessionID: SessionID,
    providerID: String,
    modelID: String?,
    kind: UsageRunKind,
    afterRelaunch: Bool = false,
    afterSwitch: Bool = false,
    startedAt: Date,
    endedAt: Date? = nil,
    exit: UsageRunExit? = nil,
    suspensions: [DateInterval] = [],
    detachedAt: Date? = nil
  ) {
    self.id = id
    self.sessionID = sessionID
    self.providerID = providerID
    self.modelID = modelID
    self.kind = kind
    self.afterRelaunch = afterRelaunch
    self.afterSwitch = afterSwitch
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.exit = exit
    self.suspensions = suspensions
    self.detachedAt = detachedAt
  }

  public var isOpen: Bool { endedAt == nil }

  /// The time it ran inside `period`, sleep taken out. An open run runs until `now`.
  public func runningTime(in period: DateInterval?, now: Date) -> TimeInterval {
    let end = max(endedAt ?? now, startedAt)
    var lifetime = DateInterval(start: startedAt, end: end)
    if let period {
      guard let clipped = lifetime.intersection(with: period) else { return 0 }
      lifetime = clipped
    }
    var total = lifetime.duration
    for suspension in Self.merged(suspensions) {
      if let overlap = lifetime.intersection(with: suspension) { total -= overlap.duration }
    }
    return max(total, 0)
  }

  /// Two suspensions that overlap are counted once.
  private static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
    var result: [DateInterval] = []
    for interval in intervals.sorted(by: { $0.start < $1.start }) {
      if let last = result.last, interval.start <= last.end {
        result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
      } else {
        result.append(interval)
      }
    }
    return result
  }
}

/// Token counters, as a CLI reported them. Never computed by the application.
public struct TokenCounts: Hashable, Codable, Sendable {
  public var input: Int
  public var cacheRead: Int
  public var cacheWrite: Int
  public var output: Int
  /// Part of `output`, when the CLI says so (Codex).
  public var reasoning: Int

  public init(
    input: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, output: Int = 0,
    reasoning: Int = 0
  ) {
    self.input = input
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
    self.output = output
    self.reasoning = reasoning
  }

  public static let zero = TokenCounts()

  public var isZero: Bool { self == .zero }

  public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
    TokenCounts(
      input: lhs.input + rhs.input,
      cacheRead: lhs.cacheRead + rhs.cacheRead,
      cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
      output: lhs.output + rhs.output,
      reasoning: lhs.reasoning + rhs.reasoning
    )
  }

  public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
    lhs = lhs + rhs
  }
}

/// A calendar day in the user's time zone, the unit tokens are kept by.
public struct LocalDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
  public let year: Int
  public let month: Int
  public let day: Int

  public init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  public init(_ date: Date, calendar: Calendar) {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
  }

  /// `2026-09-24`.
  public init?(string: String) {
    let parts = string.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    self.init(year: parts[0], month: parts[1], day: parts[2])
  }

  public var description: String {
    String(format: "%04d-%02d-%02d", year, month, day)
  }

  public func start(in calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
  }

  public func interval(in calendar: Calendar) -> DateInterval {
    let start = start(in: calendar)
    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
    return DateInterval(start: start, end: end)
  }

  public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    guard let day = LocalDay(string: value) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: value))
    }
    self = day
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}

/// The tokens one session's conversations reported, for one model on one day.
public struct TokenUsageBucket: Hashable, Sendable {
  public let sessionID: SessionID
  public let providerID: String
  /// The model the CLI said answered, which can differ from the one the session asked for.
  public let model: String
  public let day: LocalDay
  public var tokens: TokenCounts
  public var responses: Int

  public init(
    sessionID: SessionID, providerID: String, model: String, day: LocalDay,
    tokens: TokenCounts, responses: Int
  ) {
    self.sessionID = sessionID
    self.providerID = providerID
    self.model = model
    self.day = day
    self.tokens = tokens
    self.responses = responses
  }
}

/// When usage tracking was on. The first interval of a store that never had a choice made starts
/// at `distantPast`: before this feature, nobody had said not to count.
public struct UsageTrackingInterval: Hashable, Codable, Sendable {
  public var from: Date
  public var to: Date?

  public init(from: Date, to: Date? = nil) {
    self.from = from
    self.to = to
  }

  public func contains(_ date: Date) -> Bool {
    date >= from && (to.map { date < $0 } ?? true)
  }
}

extension Array where Element == UsageTrackingInterval {
  public func tracks(_ date: Date) -> Bool {
    contains { $0.contains(date) }
  }

  public var isTracking: Bool {
    last.map { $0.to == nil } ?? false
  }
}

/// Why a figure is not shown.
public enum UsageUnavailability: Hashable, Sendable {
  /// The agent writes no usage the application can read.
  case notReportedByAgent
  /// The agent does, but no transcript of this session was found and nothing was kept of one.
  case noTranscript
  /// Neither CLI reports a cost that holds together.
  case notReliable
  case trackingOff
}

public enum UsagePeriod: String, CaseIterable, Hashable, Sendable {
  case today
  case last7Days
  case last30Days
  case thisMonth
  case previousMonth
  case allTime

  /// `nil` for all time.
  public func interval(now: Date, calendar: Calendar) -> DateInterval? {
    let today = calendar.startOfDay(for: now)
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
    func daysBack(_ count: Int) -> DateInterval {
      let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
      return DateInterval(start: start, end: tomorrow)
    }
    switch self {
    case .today:
      return DateInterval(start: today, end: tomorrow)
    case .last7Days:
      return daysBack(7)
    case .last30Days:
      return daysBack(30)
    case .thisMonth:
      let start = calendar.dateInterval(of: .month, for: now)?.start ?? today
      return DateInterval(start: start, end: tomorrow)
    case .previousMonth:
      guard let thisMonth = calendar.dateInterval(of: .month, for: now),
        let previous = calendar.dateInterval(
          of: .month, for: thisMonth.start.addingTimeInterval(-1))
      else { return nil }
      return previous
    case .allTime:
      return nil
    }
  }
}

public enum UsageGrouping: String, CaseIterable, Hashable, Sendable {
  case session
  case provider
  case model
}

/// How many runs of each sort a row counts.
public struct UsageRunCounts: Hashable, Sendable {
  public var starts = 0
  public var resumes = 0
  /// New processes, with or without a summary.
  public var restarts = 0
  public var afterRelaunch = 0
  public var afterSwitch = 0

  public init() {}

  public var total: Int { starts + resumes + restarts }

  mutating func count(_ run: UsageRun) {
    switch run.kind {
    case .start: starts += 1
    case .resume: resumes += 1
    case .restartWithSummary, .restartFresh: restarts += 1
    }
    if run.afterRelaunch { afterRelaunch += 1 }
    if run.afterSwitch { afterSwitch += 1 }
  }
}

/// What one row of a usage report adds up.
public struct UsageRow: Identifiable, Hashable, Sendable {
  public enum Key: Hashable, Sendable {
    case session(SessionID)
    case provider(String)
    /// `model` is `nil` for runs that asked for the CLI's default.
    case model(providerID: String, model: String?)
    case total
  }

  public let key: Key
  public var runningTime: TimeInterval = 0
  public var runs = UsageRunCounts()
  public var tokens = TokenCounts.zero
  public var responses = 0
  /// Whether any reported token reached this row. Without it, the tokens are unavailable rather
  /// than zero.
  public var hasReportedTokens = false
  /// The providers whose runs or tokens are in this row.
  public var providerIDs: Set<String> = []

  public var id: Key { key }

  public init(key: Key) {
    self.key = key
  }
}

/// One day of a report, per provider, for the chart.
public struct UsageDay: Hashable, Sendable {
  public let day: LocalDay
  public let providerID: String
  public var runningTime: TimeInterval
  public var tokens: TokenCounts
}

public struct UsageReport: Hashable, Sendable {
  public var rows: [UsageRow]
  public var total: UsageRow
  public var days: [UsageDay]

  public init(rows: [UsageRow] = [], total: UsageRow = UsageRow(key: .total), days: [UsageDay] = [])
  {
    self.rows = rows
    self.total = total
    self.days = days
  }
}

/// Adds runs and tokens up for a period and a grouping. Pure: the same inputs give the same report.
public enum UsageAggregator {
  public static func report(
    runs: [UsageRun],
    tokens: [TokenUsageBucket],
    period: DateInterval?,
    grouping: UsageGrouping,
    now: Date,
    calendar: Calendar
  ) -> UsageReport {
    var rows: [UsageRow.Key: UsageRow] = [:]
    var total = UsageRow(key: .total)
    var days: [String: UsageDay] = [:]

    func add(_ key: UsageRow.Key, _ change: (inout UsageRow) -> Void) {
      var row = rows[key] ?? UsageRow(key: key)
      change(&row)
      rows[key] = row
      change(&total)
    }

    for run in runs {
      let time = run.runningTime(in: period, now: now)
      // A run counts in a period it ran in; its start is what is counted as a run.
      let startedInPeriod = period.map { $0.contains(run.startedAt) } ?? true
      guard time > 0 || startedInPeriod else { continue }
      let key: UsageRow.Key
      switch grouping {
      case .session: key = .session(run.sessionID)
      case .provider: key = .provider(run.providerID)
      case .model: key = .model(providerID: run.providerID, model: run.modelID)
      }
      add(key) { row in
        row.runningTime += time
        if startedInPeriod { row.runs.count(run) }
        row.providerIDs.insert(run.providerID)
      }
      for (day, seconds) in dailyTimes(of: run, within: period, now: now, calendar: calendar) {
        let dayKey = "\(day)|\(run.providerID)"
        var entry =
          days[dayKey]
          ?? UsageDay(day: day, providerID: run.providerID, runningTime: 0, tokens: .zero)
        entry.runningTime += seconds
        days[dayKey] = entry
      }
    }

    for bucket in tokens {
      // A bucket is a whole day, and the periods are made of whole days.
      if let period {
        let start = bucket.day.start(in: calendar)
        guard start >= period.start, start < period.end else { continue }
      }
      let key: UsageRow.Key
      switch grouping {
      case .session: key = .session(bucket.sessionID)
      case .provider: key = .provider(bucket.providerID)
      case .model: key = .model(providerID: bucket.providerID, model: bucket.model)
      }
      add(key) { row in
        row.tokens += bucket.tokens
        row.responses += bucket.responses
        row.hasReportedTokens = true
        row.providerIDs.insert(bucket.providerID)
      }
      let dayKey = "\(bucket.day)|\(bucket.providerID)"
      var entry =
        days[dayKey]
        ?? UsageDay(day: bucket.day, providerID: bucket.providerID, runningTime: 0, tokens: .zero)
      entry.tokens += bucket.tokens
      days[dayKey] = entry
    }

    let sortedRows = rows.values.sorted {
      if $0.runningTime != $1.runningTime { return $0.runningTime > $1.runningTime }
      return $0.tokens.input + $0.tokens.output > $1.tokens.input + $1.tokens.output
    }
    let sortedDays = days.values.sorted {
      $0.day != $1.day ? $0.day < $1.day : $0.providerID < $1.providerID
    }
    return UsageReport(rows: sortedRows, total: total, days: sortedDays)
  }

  /// The running time of a run, day by day, inside the period.
  static func dailyTimes(
    of run: UsageRun, within period: DateInterval?, now: Date, calendar: Calendar
  ) -> [(LocalDay, TimeInterval)] {
    let end = max(run.endedAt ?? now, run.startedAt)
    var day = LocalDay(run.startedAt, calendar: calendar)
    let last = LocalDay(end, calendar: calendar)
    var result: [(LocalDay, TimeInterval)] = []
    while day <= last {
      var interval = day.interval(in: calendar)
      if let period {
        guard let clipped = interval.intersection(with: period) else {
          day = LocalDay(interval.end, calendar: calendar)
          continue
        }
        interval = clipped
      }
      let seconds = run.runningTime(in: interval, now: now)
      if seconds > 0 { result.append((day, seconds)) }
      let next = LocalDay(day.interval(in: calendar).end, calendar: calendar)
      guard next > day else { break }
      day = next
    }
    return result
  }
}
