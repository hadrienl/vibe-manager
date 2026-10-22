import Foundation
import VibeDomain

/// What an agent writes and the application reads to archive sessions on its own (#405): rules
/// that say which sessions, when, and what to do with them, and protections that keep sessions out
/// of every rule.
///
/// The language is internal. The interface never shows it and offers no way to write it: the user
/// sees what `ArchiveRuleExplanation` says of it. Its keywords are English, like code.
public struct ArchiveRuleDocument: Hashable, Sendable {
  public var rules: [ArchiveRule]
  public var protections: [ArchiveProtection]

  public init(rules: [ArchiveRule] = [], protections: [ArchiveProtection] = []) {
    self.rules = rules
    self.protections = protections
  }

  public var isEmpty: Bool {
    rules.isEmpty && protections.isEmpty
  }
}

/// `rule "name" archive done sessions [where …] on … [limit N] [no catch-up]`
public struct ArchiveRule: Hashable, Sendable {
  public var name: String
  /// `nil` archives every done session.
  public var condition: ArchiveCondition?
  public var schedule: ArchiveSchedule
  /// At most this many sessions a run, the longest done first.
  public var limit: Int?
  /// `false` waits for the next time rather than catching up a missed one.
  public var catchesUp: Bool

  public init(
    name: String, condition: ArchiveCondition? = nil, schedule: ArchiveSchedule,
    limit: Int? = nil, catchesUp: Bool = true
  ) {
    self.name = name
    self.condition = condition
    self.schedule = schedule
    self.limit = limit
    self.catchesUp = catchesUp
  }
}

/// `protect where …`: a session it names is never archived by a rule.
public struct ArchiveProtection: Hashable, Sendable {
  public var condition: ArchiveCondition

  public init(condition: ArchiveCondition) {
    self.condition = condition
  }
}

public indirect enum ArchiveCondition: Hashable, Sendable {
  case all([ArchiveCondition])
  case any([ArchiveCondition])
  case not(ArchiveCondition)
  case test(ArchiveTest)
}

/// One comparison of a field with a value. Which operators and values each field takes is said by
/// `ArchiveField`, and checked by the parser.
public struct ArchiveTest: Hashable, Sendable {
  public var field: ArchiveField
  public var comparison: ArchiveComparison
  public var value: ArchiveValue

  public init(_ field: ArchiveField, _ comparison: ArchiveComparison, _ value: ArchiveValue) {
    self.field = field
    self.comparison = comparison
    self.value = value
  }
}

public enum ArchiveComparison: String, Hashable, Sendable, CaseIterable {
  case equal = "="
  case notEqual = "!="
  case `in`
  case contains
  case matches = "~"
  case atLeast = ">="
  case atMost = "<="
  case before
  case after
  case under
  /// `ticket present`, `git.dirty`: a field that is a fact on its own.
  case isTrue = "present"
  case isFalse = "absent"
}

public enum ArchiveValue: Hashable, Sendable {
  case color(String)
  case text(String)
  case word(String)
  case integer(Int)
  case duration(ArchiveDuration)
  case date(ArchiveDay)
  case list([ArchiveValue])
  case none
}

/// `3d`, `48h`, `30m`, `2w`.
public struct ArchiveDuration: Hashable, Sendable, Comparable {
  public enum Unit: String, Hashable, Sendable, CaseIterable {
    case minutes = "m"
    case hours = "h"
    case days = "d"
    case weeks = "w"

    var seconds: TimeInterval {
      switch self {
      case .minutes: 60
      case .hours: 3600
      case .days: 86_400
      case .weeks: 604_800
      }
    }
  }

  public var count: Int
  public var unit: Unit

  public init(_ count: Int, _ unit: Unit) {
    self.count = count
    self.unit = unit
  }

  /// A day is 24 hours here: `done.since >= 3d` measures time gone by, not calendar days.
  public var seconds: TimeInterval {
    TimeInterval(count) * unit.seconds
  }

  public static func < (lhs: ArchiveDuration, rhs: ArchiveDuration) -> Bool {
    lhs.seconds < rhs.seconds
  }
}

/// A day of the calendar, `2026-11-01`, read in the Mac's time zone: `before` it is before its
/// first instant, `after` it is from the next day on.
public struct ArchiveDay: Hashable, Sendable, Comparable {
  public var year: Int
  public var month: Int
  public var day: Int

  public init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  public func start(in calendar: Calendar) -> Date? {
    calendar.date(from: DateComponents(year: year, month: month, day: day))
  }

  public static func < (lhs: ArchiveDay, rhs: ArchiveDay) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }

  var text: String {
    String(format: "%04d-%02d-%02d", year, month, day)
  }
}

/// A time of the day, `18:00`, on the Mac's clock.
public struct ArchiveTime: Hashable, Sendable, Comparable {
  public var hour: Int
  public var minute: Int

  public init(hour: Int, minute: Int) {
    self.hour = hour
    self.minute = minute
  }

  public static func < (lhs: ArchiveTime, rhs: ArchiveTime) -> Bool {
    (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
  }

  var text: String {
    String(format: "%02d:%02d", hour, minute)
  }
}

/// Monday is 1 and Sunday 7, as ISO 8601 numbers them; `Calendar` numbers from Sunday.
public enum ArchiveWeekday: Int, Hashable, Sendable, CaseIterable, Comparable {
  case monday = 1
  case tuesday, wednesday, thursday, friday, saturday, sunday

  public var keyword: String {
    switch self {
    case .monday: "monday"
    case .tuesday: "tuesday"
    case .wednesday: "wednesday"
    case .thursday: "thursday"
    case .friday: "friday"
    case .saturday: "saturday"
    case .sunday: "sunday"
    }
  }

  /// The number `Calendar` gives this day: Sunday 1, Saturday 7.
  public var calendarWeekday: Int {
    rawValue % 7 + 1
  }

  public init?(calendarWeekday: Int) {
    self.init(rawValue: (calendarWeekday + 5) % 7 + 1)
  }

  public static func < (lhs: ArchiveWeekday, rhs: ArchiveWeekday) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public enum ArchiveOrdinal: String, Hashable, Sendable, CaseIterable {
  case first, second, third, fourth, last
}

/// A day of the month a monthly rule runs on.
public enum ArchiveMonthDay: Hashable, Sendable {
  /// 1 to 31. A month without that day runs on its last day.
  case number(Int)
  case lastDay
  /// `first monday`, `last friday`.
  case weekday(ArchiveOrdinal, ArchiveWeekday)
}

/// When a rule runs.
public enum ArchiveSchedule: Hashable, Sendable {
  case daily(ArchiveTime)
  /// Monday to Friday.
  case weekdays(ArchiveTime)
  case weekly([ArchiveWeekday], ArchiveTime)
  case monthly([ArchiveMonthDay], ArchiveTime)
  /// Every interval from the moment the rule was turned on. With a time, the interval is in whole
  /// days and the rule runs at that time.
  case every(ArchiveDuration, ArchiveTime?)
  /// As soon as a session matches: whenever the sessions change, and at least every 15 minutes.
  case continuously
}

// MARK: - The fields

/// What a value of a field is written as.
public enum ArchiveValueKind: Hashable, Sendable {
  case color
  case text
  case words([String])
  case integer
  case duration
  case date
  case fact
}

/// The fields a condition reads. Each says the comparisons it takes, the values it compares with,
/// and what it means: the reference for developers (`docs/archive-rules.md`) and the agent's
/// instructions are both written from these.
public enum ArchiveField: String, Hashable, Sendable, CaseIterable {
  case badgeColor = "badge.color"
  case badgeSymbol = "badge.symbol"
  case badgeKind = "badge.kind"
  case name
  case project
  case folder
  case agent
  case model
  case ticket
  case ticketHost = "ticket.host"
  case gitBranch = "git.branch"
  case gitDirty = "git.dirty"
  case coordination
  case createdSince = "created.since"
  case activitySince = "activity.since"
  case closedSince = "closed.since"
  case doneSince = "done.since"
  case created
  case activity
  case closed
  case done
  case doneFirst = "done.first"
  case reopened

  public var keyword: String { rawValue }

  public var comparisons: [ArchiveComparison] {
    switch self {
    case .badgeColor, .badgeSymbol, .agent: [.equal, .notEqual, .in]
    case .badgeKind, .coordination: [.equal, .notEqual]
    case .name, .project, .model, .gitBranch, .ticketHost:
      [.equal, .notEqual, .in, .contains, .matches]
    case .folder: [.under]
    case .ticket: [.isTrue, .isFalse]
    case .gitDirty: [.isTrue]
    case .createdSince, .activitySince, .closedSince, .doneSince: [.atLeast, .atMost]
    case .created, .activity, .closed, .done, .doneFirst: [.before, .after]
    case .reopened: [.equal, .notEqual, .atLeast, .atMost]
    }
  }

  public var valueKind: ArchiveValueKind {
    switch self {
    case .badgeColor: .color
    case .badgeSymbol, .name, .project, .folder, .model, .gitBranch, .ticketHost: .text
    case .badgeKind: .words(["symbol", "projectIcon"])
    case .agent: .words([])
    case .coordination: .words(["none", "coordinator", "child"])
    case .ticket, .gitDirty: .fact
    case .createdSince, .activitySince, .closedSince, .doneSince: .duration
    case .created, .activity, .closed, .done, .doneFirst: .date
    case .reopened: .integer
    }
  }

  /// What the field is, in English, for the reference and the agent.
  public var summary: String {
    switch self {
    case .badgeColor:
      "The colour the session's badge shows, as `#RRGGBB`. A badge that shows the project's icon "
        + "shows no colour and never matches."
    case .badgeSymbol: "The SF Symbol the badge shows, by its name. Never matches a project icon."
    case .badgeKind: "`symbol`, or `projectIcon` when the badge shows the project's icon."
    case .name: "The session's name."
    case .project: "The name of the session's group (its folder's name, or the name given to it)."
    case .folder: "The session's working folder, with `under` and a path (`~` is the home folder)."
    case .agent: "The agent's identifier: one of the agents installed, or an endpoint's."
    case .model: "The model's identifier; a session on the agent's default model has none."
    case .ticket: "`ticket present` when the session works on a ticket, `ticket absent` otherwise."
    case .ticketHost: "The host of the ticket's address, such as `github.com`."
    case .gitBranch: "The branch checked out in the session's folder."
    case .gitDirty:
      "The session's folder has changes not committed. `not git.dirty` for a clean folder."
    case .coordination: "`none`, `coordinator`, or `child` (of a coordinator)."
    case .createdSince: "Time since the session was created."
    case .activitySince: "Time since the session was last touched."
    case .closedSince: "Time since its agent was last stopped."
    case .doneSince: "Time since the session last arrived in Done."
    case .created: "The day the session was created."
    case .activity: "The day the session was last touched."
    case .closed: "The day its agent was last stopped."
    case .done: "The day the session last arrived in Done."
    case .doneFirst: "The day the session first arrived in Done."
    case .reopened: "How many times the session left Done for another column."
    }
  }

  /// An example of a test of the field, for the reference and the agent.
  public var example: String {
    switch self {
    case .badgeColor: "badge.color in [#B42318, #A65B00]"
    case .badgeSymbol: #"badge.symbol = "ladybug""#
    case .badgeKind: "badge.kind = projectIcon"
    case .name: #"name contains "spike""#
    case .project: #"project = "vibe-manager""#
    case .folder: #"folder under "~/Code/client""#
    case .agent: "agent = codex"
    case .model: #"model contains "sonnet""#
    case .ticket: "ticket present"
    case .ticketHost: #"ticket.host = "github.com""#
    case .gitBranch: #"git.branch ~ "release/*""#
    case .gitDirty: "not git.dirty"
    case .coordination: "coordination = child"
    case .createdSince: "created.since >= 30d"
    case .activitySince: "activity.since >= 2w"
    case .closedSince: "closed.since >= 12h"
    case .doneSince: "done.since >= 48h"
    case .created: "created before 2026-11-01"
    case .activity: "activity after 2026-10-01"
    case .closed: "closed before 2026-11-01"
    case .done: "done before 2026-11-01"
    case .doneFirst: "done.first before 2026-10-01"
    case .reopened: "reopened = 0"
    }
  }
}
