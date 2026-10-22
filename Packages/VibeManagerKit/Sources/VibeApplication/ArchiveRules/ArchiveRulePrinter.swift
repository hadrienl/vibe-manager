import Foundation

/// Writes a document back as text, in one canonical layout: what the store keeps, and what is sent
/// back to the agent to refine. Reading what it writes gives the same document.
public enum ArchiveRulePrinter {
  public static func text(of document: ArchiveRuleDocument) -> String {
    let blocks = document.protections.map(text(of:)) + document.rules.map(text(of:))
    return blocks.joined(separator: "\n\n")
  }

  public static func text(of rule: ArchiveRule) -> String {
    var lines = ["rule \(quoted(rule.name))"]
    if let condition = rule.condition {
      lines.append("  archive done sessions where \(text(of: condition))")
    } else {
      lines.append("  archive done sessions")
    }
    lines.append("  on \(text(of: rule.schedule))")
    if let limit = rule.limit { lines.append("  limit \(limit)") }
    if !rule.catchesUp { lines.append("  no catch-up") }
    return lines.joined(separator: "\n")
  }

  public static func text(of protection: ArchiveProtection) -> String {
    "protect where \(text(of: protection.condition))"
  }

  public static func text(of schedule: ArchiveSchedule) -> String {
    switch schedule {
    case .daily(let time): "daily at \(time.text)"
    case .weekdays(let time): "weekdays at \(time.text)"
    case .weekly(let days, let time):
      "weekly \(days.map(\.keyword).joined(separator: ", ")) at \(time.text)"
    case .monthly(let days, let time):
      "monthly \(days.map(text(of:)).joined(separator: ", ")) at \(time.text)"
    case .every(let interval, let time):
      "every \(text(of: interval))" + (time.map { " at \($0.text)" } ?? "")
    case .continuously: "continuously"
    }
  }

  static func text(of day: ArchiveMonthDay) -> String {
    switch day {
    case .number(let number): "\(number)"
    case .lastDay: "last day"
    case .weekday(let ordinal, let weekday): "\(ordinal.rawValue) \(weekday.keyword)"
    }
  }

  static func text(of duration: ArchiveDuration) -> String {
    "\(duration.count)\(duration.unit.rawValue)"
  }

  public static func text(of condition: ArchiveCondition) -> String {
    switch condition {
    case .test(let test):
      return text(of: test)
    case .not(let inner):
      return "not " + grouped(inner, unless: isSingle)
    case .all(let parts):
      // A group inside a group keeps its parentheses, so that the text reads back as the same
      // tree.
      return parts.map { grouped($0, unless: isSingle) }.joined(separator: " and ")
    case .any(let parts):
      return parts.map {
        grouped($0, unless: { if case .any = $0 { false } else { true } })
      }
      .joined(separator: " or ")
    }
  }

  private static func isSingle(_ condition: ArchiveCondition) -> Bool {
    switch condition {
    case .test, .not: true
    case .all, .any: false
    }
  }

  private static func grouped(
    _ condition: ArchiveCondition, unless bare: (ArchiveCondition) -> Bool
  ) -> String {
    bare(condition) ? text(of: condition) : "(\(text(of: condition)))"
  }

  static func text(of test: ArchiveTest) -> String {
    switch test.comparison {
    case .isTrue where test.field == .gitDirty:
      return test.field.keyword
    case .isTrue, .isFalse:
      return "\(test.field.keyword) \(test.comparison.rawValue)"
    default:
      return "\(test.field.keyword) \(test.comparison.rawValue) \(text(of: test.value))"
    }
  }

  static func text(of value: ArchiveValue) -> String {
    switch value {
    case .color(let hex): hex
    case .text(let text): quoted(text)
    case .word(let word): word
    case .integer(let number): "\(number)"
    case .duration(let duration): text(of: duration)
    case .date(let day): day.text
    case .list(let items): "[" + items.map(text(of:)).joined(separator: ", ") + "]"
    case .none: ""
    }
  }

  static func quoted(_ text: String) -> String {
    "\""
      + text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
}
