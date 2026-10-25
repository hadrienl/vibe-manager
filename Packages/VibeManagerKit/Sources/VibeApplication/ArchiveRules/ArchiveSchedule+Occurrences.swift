import Foundation

extension ArchiveSchedule {
  /// How often a rule that runs `continuously` looks at durations such as `done.since >= 2h`,
  /// when nothing in the store changes.
  public static let continuousInterval: TimeInterval = 15 * 60

  /// The first time strictly after `date` the rule runs, on `calendar`'s clock and in its time
  /// zone. `nil` for `continuously`, which has no times of its own.
  ///
  /// - A time that does not exist on a day the clocks go forward (02:30) is the first one that
  ///   does; a time that exists twice when they go back is the first of the two.
  /// - A day of the month a month does not have (31 in April) is that month's last day.
  /// - `every` counts from `activatedAt`, the moment the rule was turned on.
  public func nextOccurrence(after date: Date, calendar: Calendar, activatedAt: Date) -> Date? {
    switch self {
    case .continuously:
      return nil
    case .every(let interval, nil):
      guard date >= activatedAt else { return activatedAt.addingTimeInterval(interval.seconds) }
      let elapsed = date.timeIntervalSince(activatedAt)
      let steps = (elapsed / interval.seconds).rounded(.down) + 1
      return activatedAt.addingTimeInterval(steps * interval.seconds)
    case .every(let interval, let time?):
      let days = interval.unit == .weeks ? interval.count * 7 : interval.count
      let anchor = calendar.startOfDay(for: activatedAt)
      // Never before the rule was turned on: the day it is counts only if its time is to come.
      return firstDay(after: max(date, activatedAt), calendar: calendar, time: time) { day in
        guard let offset = calendar.dateComponents([.day], from: anchor, to: day).day else {
          return false
        }
        return offset >= 0 && offset % days == 0
      }
    case .daily(let time):
      return firstDay(after: date, calendar: calendar, time: time) { _ in true }
    case .weekdays(let time):
      return firstDay(after: date, calendar: calendar, time: time) { day in
        guard let weekday = ArchiveWeekday(calendarWeekday: calendar.component(.weekday, from: day))
        else { return false }
        return weekday <= .friday
      }
    case .weekly(let days, let time):
      return firstDay(after: date, calendar: calendar, time: time) { day in
        ArchiveWeekday(calendarWeekday: calendar.component(.weekday, from: day))
          .map(days.contains) ?? false
      }
    case .monthly(let days, let time):
      return firstDay(after: date, calendar: calendar, time: time) { day in
        days.contains { $0.matches(day, calendar: calendar) }
      }
    }
  }

  /// The times the rule runs from `start` to `end`, both included, at most `limit` of them.
  public func occurrences(
    from start: Date, through end: Date, calendar: Calendar, activatedAt: Date,
    limit: Int = 2000
  ) -> [Date] {
    var result: [Date] = []
    var cursor = start.addingTimeInterval(-0.001)
    while result.count < limit,
      let next = nextOccurrence(after: cursor, calendar: calendar, activatedAt: activatedAt),
      next <= end
    {
      result.append(next)
      cursor = next
    }
    return result
  }

  /// The last time the rule ran at or before `date`, after `since`: the one a run that comes late
  /// stands for.
  public func latestOccurrence(
    atOrBefore date: Date, since: Date, calendar: Calendar, activatedAt: Date
  ) -> Date? {
    var latest: Date?
    var cursor = since
    while let next = nextOccurrence(after: cursor, calendar: calendar, activatedAt: activatedAt),
      next <= date
    {
      latest = next
      cursor = next
    }
    return latest
  }

  /// The first day, from the one `date` falls on, that `matches`, at `time`, after `date`. Looks
  /// at most fourteen months ahead: every schedule of the language runs at least once a month.
  private func firstDay(
    after date: Date, calendar: Calendar, time: ArchiveTime, matches: (Date) -> Bool
  ) -> Date? {
    var day = calendar.startOfDay(for: date)
    for _ in 0..<430 {
      if matches(day), let occurrence = Self.time(time, on: day, calendar: calendar),
        occurrence > date
      {
        return occurrence
      }
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
      day = calendar.startOfDay(for: next)
    }
    return nil
  }

  /// `time` on `day`, or the first time after it that exists when the clocks skip it.
  static func time(_ time: ArchiveTime, on day: Date, calendar: Calendar) -> Date? {
    let start = calendar.startOfDay(for: day)
    guard
      let occurrence = calendar.nextDate(
        after: start.addingTimeInterval(-1),
        matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
        matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    else { return nil }
    // `nextTime` moves a skipped time to the first hour that exists, which is still that day.
    return calendar.isDate(occurrence, inSameDayAs: start) ? occurrence : nil
  }
}

extension ArchiveMonthDay {
  func matches(_ day: Date, calendar: Calendar) -> Bool {
    let number = calendar.component(.day, from: day)
    guard let length = calendar.range(of: .day, in: .month, for: day)?.count else { return false }
    switch self {
    case .number(let wanted):
      return number == min(wanted, length)
    case .lastDay:
      return number == length
    case .weekday(let ordinal, let weekday):
      guard calendar.component(.weekday, from: day) == weekday.calendarWeekday else {
        return false
      }
      switch ordinal {
      case .first: return number <= 7
      case .second: return (8...14).contains(number)
      case .third: return (15...21).contains(number)
      case .fourth: return (22...28).contains(number)
      case .last: return number + 7 > length
      }
    }
  }
}
