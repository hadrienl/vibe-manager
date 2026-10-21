import Foundation
import VibeDomain

/// The names the application gives to what a rule names by value: the colours of the palette,
/// the symbols, the agents. A value without a name is shown as it is written.
public struct ArchiveRuleVocabulary: Sendable {
  /// Keyed by `#RRGGBB`, upper case.
  public var colorNames: [String: String]
  public var symbolNames: [String: String]
  public var agentNames: [String: String]

  public init(
    colorNames: [String: String] = [:], symbolNames: [String: String] = [:],
    agentNames: [String: String] = [:]
  ) {
    self.colorNames = colorNames.reduce(into: [:]) { $0[$1.key.uppercased()] = $1.value }
    self.symbolNames = symbolNames
    self.agentNames = agentNames
  }

  /// `Red (#B42318)`, or the hex alone for a colour the palette does not name.
  public func color(_ hex: String) -> String {
    let hex = hex.uppercased()
    guard let name = colorNames[hex] else { return hex }
    return "\(name) (\(hex))"
  }

  func symbol(_ name: String) -> String {
    symbolNames[name].map { "\($0) (\(name))" } ?? name
  }

  func agent(_ id: String) -> String {
    agentNames[id] ?? id
  }
}

/// What a rule does, said in the application's language, from the rule itself: the user reads
/// this, never the rule.
public struct ArchiveRuleExplanation: Sendable {
  public var vocabulary: ArchiveRuleVocabulary
  public var calendar: Calendar
  public var locale: Locale

  public init(
    vocabulary: ArchiveRuleVocabulary = ArchiveRuleVocabulary(), calendar: Calendar = .current,
    locale: Locale = .current
  ) {
    self.vocabulary = vocabulary
    var calendar = calendar
    calendar.locale = locale
    self.calendar = calendar
    self.locale = locale
  }

  // MARK: Rules and protections

  /// “Every Friday at 6:00 PM, archives the done sessions where the badge is Green (#1E7F4D).”,
  /// followed by what its options and its schedule's edge cases add.
  public func sentence(of rule: ArchiveRule) -> String {
    let when = schedule(rule.schedule)
    var sentences: [String]
    if let condition = rule.condition {
      let what = clause(condition)
      sentences = [
        String(
          localized: "\(when), archives the done sessions where \(what).", bundle: .module,
          locale: locale,
          comment:
            "An automatic archive rule. The first part says when (“Every Friday at 6:00 PM”), the second which sessions (“the badge is Green”)."
        )
      ]
    } else {
      sentences = [
        String(
          localized: "\(when), archives every done session.", bundle: .module, locale: locale,
          comment: "An automatic archive rule without condition. The argument says when.")
      ]
    }
    if case .monthly(let days, _) = rule.schedule,
      let longest = days.compactMap({ if case .number(let n) = $0, n > 28 { n } else { nil } })
        .max()
    {
      sentences.append(
        String(
          localized: "A month without day \(longest) runs on its last day.", bundle: .module,
          locale: locale,
          comment: "Said of a monthly archive rule asked for the 29th, 30th or 31st."))
    }
    if let limit = rule.limit {
      sentences.append(
        String(
          localized: "At most \(limit) sessions each time, the longest done first.",
          bundle: .module, locale: locale,
          comment: "The limit of an automatic archive rule: how many sessions a run archives."))
    }
    if !rule.catchesUp {
      sentences.append(
        String(
          localized: "A time missed while the Mac is off is not caught up.", bundle: .module,
          locale: locale, comment: "Said of an automatic archive rule that skips missed times."))
    }
    return capitalized(sentences.joined(separator: " "))
  }

  /// “Never a session where the group is “client-x”, whatever the rule.”
  public func sentence(of protection: ArchiveProtection) -> String {
    let what = clause(protection.condition)
    return capitalized(
      String(
        localized: "Never a session where \(what), whatever the rule.", bundle: .module,
        locale: locale,
        comment: "A protection of the automatic archive: sessions no rule ever archives."))
  }

  // MARK: Schedules

  /// When a rule runs, as the start of a sentence: “Every Friday at 6:00 PM”.
  public func schedule(_ schedule: ArchiveSchedule) -> String {
    switch schedule {
    case .daily(let time):
      let time = self.time(time)
      return String(
        localized: "Every day at \(time)", bundle: .module, locale: locale,
        comment: "When an automatic archive rule runs. The argument is a time.")
    case .weekdays(let time):
      let time = self.time(time)
      return String(
        localized: "Monday to Friday at \(time)", bundle: .module, locale: locale,
        comment: "When an automatic archive rule runs. The argument is a time.")
    case .weekly(let days, let time):
      let days = days.map(weekday).formatted(.list(type: .and).locale(locale))
      let time = self.time(time)
      return String(
        localized: "Every \(days) at \(time)", bundle: .module, locale: locale,
        comment:
          "When an automatic archive rule runs: one or more days of the week (“Friday”, “Monday and Thursday”), then a time."
      )
    case .monthly(let days, let time):
      let days = days.map(monthDay).formatted(.list(type: .and).locale(locale))
      let time = self.time(time)
      return String(
        localized: "On \(days) of every month at \(time)", bundle: .module, locale: locale,
        comment:
          "When an automatic archive rule runs: days of the month (“day 15”, “day 1 and day 15”, “the last day”, “the last Friday”), then a time."
      )
    case .every(let interval, nil):
      let interval = duration(interval)
      return String(
        localized: "Every \(interval), counted from when the rule was turned on", bundle: .module,
        locale: locale, comment: "When an automatic archive rule runs. The argument is “3 days”.")
    case .every(let interval, let time?):
      let interval = duration(interval)
      let time = self.time(time)
      return String(
        localized: "Every \(interval) at \(time), counted from when the rule was turned on",
        bundle: .module, locale: locale,
        comment: "When an automatic archive rule runs: an interval (“3 days”), then a time.")
    case .continuously:
      return String(
        localized: "As soon as a session matches", bundle: .module, locale: locale,
        comment: "When an automatic archive rule runs: continuously.")
    }
  }

  /// A short label of when a rule runs, for a badge: “Friday · 6:00 PM”.
  public func shortSchedule(_ schedule: ArchiveSchedule) -> String {
    switch schedule {
    case .daily(let time), .weekdays(let time):
      return self.schedule(schedule).replacingOccurrences(
        of: " " + self.time(time), with: " · " + self.time(time))
    case .weekly(let days, let time):
      return capitalized(days.map(weekday).formatted(.list(type: .and).locale(locale)))
        + " · " + self.time(time)
    case .monthly(let days, let time):
      return capitalized(days.map(monthDay).formatted(.list(type: .and).locale(locale)))
        + " · " + self.time(time)
    case .every(let interval, let time):
      let interval = duration(interval)
      let every = String(
        localized: "Every \(interval)", bundle: .module, locale: locale,
        comment: "A short label of when an automatic archive rule runs: “Every 3 days”.")
      return time.map { every + " · " + self.time($0) } ?? every
    case .continuously:
      return String(
        localized: "Continuously", bundle: .module, locale: locale,
        comment: "A short label of when an automatic archive rule runs.")
    }
  }

  func time(_ time: ArchiveTime) -> String {
    let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    let date = ArchiveSchedule.time(time, on: day, calendar: calendar) ?? day
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    style.locale = locale
    style.timeZone = calendar.timeZone
    return date.formatted(style)
  }

  func weekday(_ day: ArchiveWeekday) -> String {
    calendar.weekdaySymbols[day.calendarWeekday - 1]
  }

  func monthDay(_ day: ArchiveMonthDay) -> String {
    switch day {
    case .number(let number):
      return String(
        localized: "day \(number)", bundle: .module, locale: locale,
        comment:
          "A day of the month an archive rule runs on, as in “On day 15 of every month”. The argument is the day's number."
      )
    case .lastDay:
      return String(
        localized: "the last day", bundle: .module, locale: locale,
        comment: "The last day of the month, as in “the last day of every month”.")
    case .weekday(let ordinal, let weekday):
      let name = self.weekday(weekday)
      switch ordinal {
      case .first:
        return String(
          localized: "the first \(name)", bundle: .module, locale: locale,
          comment: "As in “the first Monday of every month”. The argument is a day of the week.")
      case .second:
        return String(
          localized: "the second \(name)", bundle: .module, locale: locale,
          comment: "As in “the second Monday of every month”. The argument is a day of the week.")
      case .third:
        return String(
          localized: "the third \(name)", bundle: .module, locale: locale,
          comment: "As in “the third Monday of every month”. The argument is a day of the week.")
      case .fourth:
        return String(
          localized: "the fourth \(name)", bundle: .module, locale: locale,
          comment: "As in “the fourth Monday of every month”. The argument is a day of the week.")
      case .last:
        return String(
          localized: "the last \(name)", bundle: .module, locale: locale,
          comment: "As in “the last Friday of every month”. The argument is a day of the week.")
      }
    }
  }

  public func duration(_ duration: ArchiveDuration) -> String {
    var components = DateComponents()
    switch duration.unit {
    case .minutes: components.minute = duration.count
    case .hours: components.hour = duration.count
    case .days: components.day = duration.count
    case .weeks: components.weekOfMonth = duration.count
    }
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .full
    formatter.allowedUnits = [.minute, .hour, .day, .weekOfMonth]
    formatter.calendar = calendar
    return formatter.string(from: components) ?? "\(duration.count)\(duration.unit.rawValue)"
  }

  func day(_ day: ArchiveDay) -> String {
    guard let date = day.start(in: calendar) else { return day.text }
    var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
    style.locale = locale
    style.timeZone = calendar.timeZone
    return date.formatted(style)
  }

  // MARK: Conditions

  /// A condition as a clause that follows “where”: “the badge is Red (#B42318) and the folder is
  /// clean”.
  public func clause(_ condition: ArchiveCondition) -> String {
    switch condition {
    case .test(let test):
      return clause(test, negated: false)
    case .not(.test(let test)):
      return clause(test, negated: true)
    case .not(let inner):
      let inner = clause(inner)
      return String(
        localized: "not (\(inner))", bundle: .module, locale: locale,
        comment: "The opposite of a group of conditions of an archive rule.")
    case .all(let parts):
      return parts.map { grouped($0) }.formatted(.list(type: .and).locale(locale))
    case .any(let parts):
      return parts.map { grouped($0) }.formatted(.list(type: .or).locale(locale))
    }
  }

  private func grouped(_ condition: ArchiveCondition) -> String {
    switch condition {
    case .all, .any: "(\(clause(condition)))"
    default: clause(condition)
    }
  }

  private func values(_ value: ArchiveValue, _ render: (ArchiveValue) -> String) -> String {
    if case .list(let items) = value {
      return items.map(render).formatted(.list(type: .or).locale(locale))
    }
    return render(value)
  }

  private func plain(_ value: ArchiveValue) -> String {
    switch value {
    case .text(let text): "“\(text)”"
    case .word(let word): word
    case .color(let hex): vocabulary.color(hex)
    case .integer(let number): number.formatted(.number.locale(locale))
    case .duration(let interval): duration(interval)
    case .date(let date): day(date)
    case .list(let items): items.map(plain).formatted(.list(type: .or).locale(locale))
    case .none: ""
    }
  }

  func clause(_ test: ArchiveTest, negated: Bool) -> String {
    let positive: Bool
    switch test.comparison {
    case .notEqual: positive = negated
    default: positive = !negated
    }
    switch test.field {
    case .badgeColor:
      let color = values(test.value) { value in
        if case .color(let hex) = value { return vocabulary.color(hex) }
        return plain(value)
      }
      return positive
        ? String(
          localized: "the badge is \(color)", bundle: .module, locale: locale,
          comment: "A condition of an archive rule. The argument is a colour, “Red (#B42318)”.")
        : String(
          localized: "the badge is not \(color)", bundle: .module, locale: locale,
          comment: "A condition of an archive rule. The argument is a colour, “Red (#B42318)”.")
    case .badgeSymbol:
      let symbol = values(test.value) { value in
        if case .text(let name) = value { return vocabulary.symbol(name) }
        return plain(value)
      }
      return positive
        ? String(
          localized: "the badge shows \(symbol)", bundle: .module, locale: locale,
          comment: "A condition of an archive rule. The argument is a symbol's name.")
        : String(
          localized: "the badge does not show \(symbol)", bundle: .module, locale: locale,
          comment: "A condition of an archive rule. The argument is a symbol's name.")
    case .badgeKind:
      let isIcon = test.value == .word("projectIcon")
      switch (isIcon, positive) {
      case (true, true), (false, false):
        return String(
          localized: "the badge shows the project's icon", bundle: .module, locale: locale,
          comment: "A condition of an archive rule.")
      case (true, false), (false, true):
        return String(
          localized: "the badge shows a symbol", bundle: .module, locale: locale,
          comment: "A condition of an archive rule: the badge does not show the project's icon.")
      }
    case .agent:
      let agent = values(test.value) { value in
        if case .word(let id) = value { return vocabulary.agent(id) }
        return plain(value)
      }
      return positive
        ? String(
          localized: "the agent is \(agent)", bundle: .module, locale: locale,
          comment: "A condition of an archive rule. The argument is an agent's name.")
        : String(
          localized: "the agent is not \(agent)", bundle: .module, locale: locale,
          comment: "A condition of an archive rule. The argument is an agent's name.")
    case .name, .project, .model, .gitBranch, .ticketHost:
      return textClause(test, negated: negated)
    case .folder:
      let path = plain(test.value)
      return negated
        ? String(
          localized: "the folder is not in \(path)", bundle: .module, locale: locale,
          comment: "A condition of an archive rule. The argument is a folder's path.")
        : String(
          localized: "the folder is in \(path)", bundle: .module, locale: locale,
          comment: "A condition of an archive rule. The argument is a folder's path.")
    case .ticket:
      return (test.comparison == .isTrue) != negated
        ? String(
          localized: "the session has a ticket", bundle: .module, locale: locale,
          comment: "A condition of an archive rule.")
        : String(
          localized: "the session has no ticket", bundle: .module, locale: locale,
          comment: "A condition of an archive rule.")
    case .gitDirty:
      return negated
        ? String(
          localized: "the folder has no uncommitted changes", bundle: .module, locale: locale,
          comment: "A condition of an archive rule: the session's Git folder is clean.")
        : String(
          localized: "the folder has uncommitted changes", bundle: .module, locale: locale,
          comment: "A condition of an archive rule.")
    case .coordination:
      return coordinationClause(test.value, positive: positive)
    case .createdSince, .activitySince, .closedSince, .doneSince:
      return elapsedClause(test, negated: negated)
    case .created, .activity, .closed, .done, .doneFirst:
      return dayClause(test, negated: negated)
    case .reopened:
      return reopenedClause(test, negated: negated)
    }
  }

  private func textClause(_ test: ArchiveTest, negated: Bool) -> String {
    let subject: String
    switch test.field {
    case .name:
      subject = String(
        localized: "the name", bundle: .module, locale: locale,
        comment: "The subject of a condition of an archive rule: the session's name.")
    case .project:
      subject = String(
        localized: "the group", bundle: .module, locale: locale,
        comment:
          "The subject of a condition of an archive rule: the session's group in the sidebar.")
    case .model:
      subject = String(
        localized: "the model", bundle: .module, locale: locale,
        comment: "The subject of a condition of an archive rule: the agent's model.")
    case .gitBranch:
      subject = String(
        localized: "the branch", bundle: .module, locale: locale,
        comment: "The subject of a condition of an archive rule: the Git branch.")
    default:
      subject = String(
        localized: "the ticket's site", bundle: .module, locale: locale,
        comment: "The subject of a condition of an archive rule: the host of the ticket's address.")
    }
    let value = plain(test.value)
    switch (test.comparison, negated) {
    case (.equal, false), (.in, false), (.notEqual, true):
      return String(
        localized: "\(subject) is \(value)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule: “the name is “spike””.")
    case (.equal, true), (.in, true), (.notEqual, false):
      return String(
        localized: "\(subject) is not \(value)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule: “the name is not “spike””.")
    case (.contains, false):
      return String(
        localized: "\(subject) contains \(value)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule: “the name contains “spike””.")
    case (.contains, true):
      return String(
        localized: "\(subject) does not contain \(value)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule: “the name does not contain “spike””.")
    case (_, false):
      return String(
        localized: "\(subject) matches \(value)", bundle: .module, locale: locale,
        comment:
          "A condition of an archive rule: “the branch matches “spike/*””, a pattern where * is any text."
      )
    case (_, true):
      return String(
        localized: "\(subject) does not match \(value)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule: “the branch does not match “spike/*””.")
    }
  }

  private func coordinationClause(_ value: ArchiveValue, positive: Bool) -> String {
    switch (value, positive) {
    case (.word("coordinator"), true):
      return String(
        localized: "the session coordinates others", bundle: .module, locale: locale,
        comment: "A condition of an archive rule.")
    case (.word("coordinator"), false):
      return String(
        localized: "the session coordinates no other", bundle: .module, locale: locale,
        comment: "A condition of an archive rule.")
    case (.word("child"), true):
      return String(
        localized: "the session is the child of a coordinator", bundle: .module, locale: locale,
        comment: "A condition of an archive rule.")
    case (.word("child"), false):
      return String(
        localized: "the session is not the child of a coordinator", bundle: .module,
        locale: locale, comment: "A condition of an archive rule.")
    case (_, true):
      return String(
        localized: "the session takes no part in a coordination", bundle: .module, locale: locale,
        comment: "A condition of an archive rule: neither a coordinator nor its child.")
    case (_, false):
      return String(
        localized: "the session takes part in a coordination", bundle: .module, locale: locale,
        comment: "A condition of an archive rule: a coordinator or its child.")
    }
  }

  private func elapsedClause(_ test: ArchiveTest, negated: Bool) -> String {
    guard case .duration(let interval) = test.value else { return "" }
    let span = duration(interval)
    // `>=` and not `<=` say “at least”; `<=` and not `>=` say “at most”.
    let atLeast = (test.comparison == .atLeast) != negated
    switch (test.field, atLeast) {
    case (.createdSince, true):
      return String(
        localized: "it was created at least \(span) ago", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is “3 days”.")
    case (.createdSince, false):
      return String(
        localized: "it was created at most \(span) ago", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is “3 days”.")
    case (.activitySince, true):
      return String(
        localized: "it was last touched at least \(span) ago", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is “3 days”.")
    case (.activitySince, false):
      return String(
        localized: "it was last touched at most \(span) ago", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is “3 days”.")
    case (.closedSince, true):
      return String(
        localized: "its agent stopped at least \(span) ago", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is “3 days”.")
    case (.closedSince, false):
      return String(
        localized: "its agent stopped at most \(span) ago", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is “3 days”.")
    case (_, true):
      return String(
        localized: "it has been done for at least \(span)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is “3 days”.")
    case (_, false):
      return String(
        localized: "it has been done for at most \(span)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is “3 days”.")
    }
  }

  private func dayClause(_ test: ArchiveTest, negated: Bool) -> String {
    guard case .date(let value) = test.value else { return "" }
    let date = day(value)
    let before = (test.comparison == .before) != negated
    // Not before a day is on that day or after it; not after it, on it or before.
    let inclusive = negated
    switch (test.field, before, inclusive) {
    case (.created, true, false):
      return String(
        localized: "it was created before \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.created, true, true):
      return String(
        localized: "it was created on or before \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.created, false, false):
      return String(
        localized: "it was created after \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.created, false, true):
      return String(
        localized: "it was created on or after \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.activity, true, false):
      return String(
        localized: "it was last touched before \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.activity, true, true):
      return String(
        localized: "it was last touched on or before \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.activity, false, false):
      return String(
        localized: "it was last touched after \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.activity, false, true):
      return String(
        localized: "it was last touched on or after \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.closed, true, false):
      return String(
        localized: "its agent stopped before \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.closed, true, true):
      return String(
        localized: "its agent stopped on or before \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.closed, false, false):
      return String(
        localized: "its agent stopped after \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.closed, false, true):
      return String(
        localized: "its agent stopped on or after \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.doneFirst, true, false):
      return String(
        localized: "it was first done before \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.doneFirst, true, true):
      return String(
        localized: "it was first done on or before \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.doneFirst, false, false):
      return String(
        localized: "it was first done after \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (.doneFirst, false, true):
      return String(
        localized: "it was first done on or after \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (_, true, false):
      return String(
        localized: "it was done before \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (_, true, true):
      return String(
        localized: "it was done on or before \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (_, false, false):
      return String(
        localized: "it was done after \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    case (_, false, true):
      return String(
        localized: "it was done on or after \(date)", bundle: .module, locale: locale,
        comment: "A condition of an archive rule. The argument is a day.")
    }
  }

  private func reopenedClause(_ test: ArchiveTest, negated: Bool) -> String {
    guard case .integer(let written) = test.value else { return "" }
    var comparison = test.comparison
    var count = written
    if negated {
      switch comparison {
      case .equal: comparison = .notEqual
      case .notEqual: comparison = .equal
      case .atLeast:
        comparison = .atMost
        count -= 1
      default:
        comparison = .atLeast
        count += 1
      }
    }
    switch comparison {
    case .equal where count == 0, .atMost where count <= 0:
      return String(
        localized: "it was never reopened", bundle: .module, locale: locale,
        comment: "A condition of an archive rule: it never left Done for another column.")
    case .notEqual where count == 0, .atLeast where count == 1:
      return String(
        localized: "it was reopened at least once", bundle: .module, locale: locale,
        comment: "A condition of an archive rule.")
    case .equal:
      return String(
        localized: "it was reopened \(count) times", bundle: .module, locale: locale,
        comment: "A condition of an archive rule: how many times it left Done.")
    case .notEqual:
      return String(
        localized: "it was not reopened exactly \(count) times", bundle: .module, locale: locale,
        comment: "A condition of an archive rule: how many times it left Done.")
    case .atLeast:
      return String(
        localized: "it was reopened at least \(count) times", bundle: .module, locale: locale,
        comment: "A condition of an archive rule: how many times it left Done.")
    default:
      return String(
        localized: "it was reopened at most \(count) times", bundle: .module, locale: locale,
        comment: "A condition of an archive rule: how many times it left Done.")
    }
  }

  private func capitalized(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.uppercased() + text.dropFirst()
  }
}
