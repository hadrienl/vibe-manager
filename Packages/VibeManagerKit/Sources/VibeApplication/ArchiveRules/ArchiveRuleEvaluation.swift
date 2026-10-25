import Foundation
import VibeDomain

/// A session as the rules see it: the session itself, and what the application knows of it that
/// the store does not keep. A fact it does not know is `nil`, and no rule acts on a guess.
public struct ArchiveCandidate: Identifiable, Hashable, Sendable {
  public var session: WorkSession
  /// The name of its group, as the sidebar shows it.
  public var project: String?
  /// Its working folder.
  public var folder: String?
  /// The branch checked out in its folder, if known.
  public var branch: String?
  /// Whether its folder has changes not committed, if known.
  public var isDirty: Bool?
  /// Its agent, or a command in one of its terminals, runs: a rule never archives it.
  public var isRunning: Bool

  public var id: SessionID { session.id }

  public init(
    session: WorkSession, project: String? = nil, folder: String? = nil, branch: String? = nil,
    isDirty: Bool? = nil, isRunning: Bool = false
  ) {
    self.session = session
    self.project = project
    self.folder = folder ?? session.repositories.first?.path
    self.branch = branch
    self.isDirty = isDirty
    self.isRunning = isRunning
  }

  /// When it last arrived in Done, read in its history (#406).
  public var doneAt: Date? {
    session.statusHistory.entries.last { $0.to == .done }?.date
  }
}

/// What a rule does with one session, and why.
public enum ArchiveVerdict: Hashable, Sendable {
  /// It matches, nothing protects it and nothing runs in it: the rule archives it.
  case archive
  /// Not in Done: the rules only archive finished sessions.
  case notDone
  /// A protection names it.
  case protected(ArchiveProtection)
  /// It does not match: the part of the condition that it fails.
  case notMatching(ArchiveCondition)
  /// It matches, but its agent or a command runs in it.
  case running
  /// It matches, but the user took it out of the archive since it was last done.
  case unarchived
  /// It matches, but the rule's limit was reached this time.
  case overLimit

  public var isSkip: Bool {
    switch self {
    case .running, .unarchived, .overLimit: true
    default: false
    }
  }
}

/// What one run of a rule does: the sessions it archives, the longest done first, and the ones it
/// skips.
public struct ArchiveRunPlan: Hashable, Sendable {
  public var archived: [SessionID]
  public var skipped: [SessionID: ArchiveVerdict]

  public init(archived: [SessionID] = [], skipped: [SessionID: ArchiveVerdict] = [:]) {
    self.archived = archived
    self.skipped = skipped
  }
}

public enum ArchiveRuleEvaluation {
  /// What `rule` does with `candidate` at `now`, before its limit.
  public static func verdict(
    of candidate: ArchiveCandidate, rule: ArchiveRule, protections: [ArchiveProtection],
    now: Date, calendar: Calendar
  ) -> ArchiveVerdict {
    let session = candidate.session
    guard session.taskStatus == .done else { return .notDone }
    // A protection that cannot be told for sure protects: a rule never acts on a guess.
    if let protection = protections.first(where: {
      evaluate($0.condition, candidate, now: now, calendar: calendar) != false
    }) {
      return .protected(protection)
    }
    if let condition = rule.condition,
      evaluate(condition, candidate, now: now, calendar: calendar) != true
    {
      return .notMatching(failing(condition, candidate, now: now, calendar: calendar))
    }
    if candidate.isRunning { return .running }
    if cameBackFromArchive(session) { return .unarchived }
    return .archive
  }

  /// A session the user unarchived, or brought back with ⌘Z, since it was last done: a rule does
  /// not send it back. It is a candidate again once it has left Done and come back.
  public static func cameBackFromArchive(_ session: WorkSession) -> Bool {
    guard let entry = session.statusHistory.entries.last(where: { $0.to == .done }) else {
      return false
    }
    return entry.from == .archived
  }

  /// One run of `rule` over `candidates`.
  public static func plan(
    rule: ArchiveRule, protections: [ArchiveProtection], candidates: [ArchiveCandidate],
    now: Date, calendar: Calendar
  ) -> ArchiveRunPlan {
    var plan = ArchiveRunPlan()
    var eligible: [ArchiveCandidate] = []
    for candidate in candidates {
      let verdict = verdict(
        of: candidate, rule: rule, protections: protections, now: now, calendar: calendar)
      switch verdict {
      case .archive: eligible.append(candidate)
      case .running, .unarchived: plan.skipped[candidate.id] = verdict
      default: break
      }
    }
    eligible.sort {
      ($0.doneAt ?? .distantPast, $0.id.description) < (
        $1.doneAt ?? .distantPast, $1.id.description
      )
    }
    let limit = rule.limit ?? eligible.count
    plan.archived = eligible.prefix(limit).map(\.id)
    for candidate in eligible.dropFirst(limit) { plan.skipped[candidate.id] = .overLimit }
    return plan
  }

  // MARK: Conditions

  /// `true`, `false`, or `nil` when a fact the condition needs is not known: `not` of an unknown is
  /// unknown, `and` is false as soon as one part is, `or` true as soon as one part is.
  public static func evaluate(
    _ condition: ArchiveCondition, _ candidate: ArchiveCandidate, now: Date, calendar: Calendar
  ) -> Bool? {
    switch condition {
    case .test(let test):
      return evaluate(test, candidate, now: now, calendar: calendar)
    case .not(let inner):
      return evaluate(inner, candidate, now: now, calendar: calendar).map(!)
    case .all(let parts):
      var result: Bool? = true
      for part in parts {
        switch evaluate(part, candidate, now: now, calendar: calendar) {
        case false?: return false
        case nil: result = nil
        case true?: break
        }
      }
      return result
    case .any(let parts):
      var result: Bool? = false
      for part in parts {
        switch evaluate(part, candidate, now: now, calendar: calendar) {
        case true?: return true
        case nil: result = nil
        case false?: break
        }
      }
      return result
    }
  }

  /// The smallest part of `condition` that keeps `candidate` from matching it.
  static func failing(
    _ condition: ArchiveCondition, _ candidate: ArchiveCandidate, now: Date, calendar: Calendar
  ) -> ArchiveCondition {
    switch condition {
    case .all(let parts):
      guard
        let part = parts.first(where: {
          evaluate($0, candidate, now: now, calendar: calendar) != true
        })
      else { return condition }
      return failing(part, candidate, now: now, calendar: calendar)
    case .any(let parts) where parts.count == 1:
      return failing(parts[0], candidate, now: now, calendar: calendar)
    default:
      return condition
    }
  }

  static func evaluate(
    _ test: ArchiveTest, _ candidate: ArchiveCandidate, now: Date, calendar: Calendar
  ) -> Bool? {
    let session = candidate.session
    let showsIcon = session.appearance.iconID != nil
    switch test.field {
    case .badgeColor:
      // A badge showing the project's icon shows no colour: it never answers to one.
      guard !showsIcon else { return false }
      return compareWords(String(session.appearance.colorHex.prefix(7)), test, exact: false)
    case .badgeSymbol:
      guard !showsIcon else { return false }
      return compareWords(session.appearance.symbolName, test, exact: true)
    case .badgeKind:
      return compareWords(showsIcon ? "projectIcon" : "symbol", test, exact: true)
    case .name:
      return compareText(session.name, test)
    case .project:
      return compareText(candidate.project, test)
    case .folder:
      guard let folder = candidate.folder, case .text(let path) = test.value else { return false }
      return isFolder(folder, under: path)
    case .agent:
      return compareWords(session.agent?.providerID, test, exact: false)
    case .model:
      return compareText(session.agent?.modelID, test)
    case .ticket:
      let present = session.ticket?.url != nil
      return test.comparison == .isTrue ? present : !present
    case .ticketHost:
      return compareText(session.ticket?.url?.host(), test)
    case .gitBranch:
      guard let branch = candidate.branch else { return nil }
      return compareText(branch, test)
    case .gitDirty:
      return candidate.isDirty
    case .coordination:
      let role: String
      switch session.coordination {
      case nil: role = "none"
      case .coordinator?: role = "coordinator"
      case .child?: role = "child"
      }
      return compareWords(role, test, exact: true)
    case .createdSince:
      return compareElapsed(since: session.createdAt, test, now: now)
    case .activitySince:
      return compareElapsed(since: session.updatedAt, test, now: now)
    case .closedSince:
      return compareElapsed(since: session.closedAt, test, now: now)
    case .doneSince:
      return compareElapsed(since: candidate.doneAt, test, now: now)
    case .created:
      return compareDay(session.createdAt, test, calendar: calendar)
    case .activity:
      return compareDay(session.updatedAt, test, calendar: calendar)
    case .closed:
      return compareDay(session.closedAt, test, calendar: calendar)
    case .done:
      return compareDay(candidate.doneAt, test, calendar: calendar)
    case .doneFirst:
      return compareDay(session.statusHistory.firstEntry(into: .done), test, calendar: calendar)
    case .reopened:
      guard case .integer(let wanted) = test.value else { return false }
      let count = session.statusHistory.reopenCount
      switch test.comparison {
      case .equal: return count == wanted
      case .notEqual: return count != wanted
      case .atLeast: return count >= wanted
      case .atMost: return count <= wanted
      default: return false
      }
    }
  }

  // MARK: Comparing

  static func folded(_ text: String) -> String {
    text.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
  }

  private static func values(of value: ArchiveValue) -> [ArchiveValue] {
    if case .list(let items) = value { return items }
    return [value]
  }

  private static func word(of value: ArchiveValue) -> String? {
    switch value {
    case .color(let text), .text(let text), .word(let text): text
    default: nil
    }
  }

  /// Identifiers, colours and symbols: compared whole, ignoring case unless `exact`.
  private static func compareWords(_ actual: String?, _ test: ArchiveTest, exact: Bool) -> Bool {
    let wanted = values(of: test.value).compactMap(word(of:))
    let isOne =
      actual.map { actual in
        wanted.contains { exact ? $0 == actual : folded($0) == folded(actual) }
      } ?? false
    switch test.comparison {
    case .equal, .in: return isOne
    case .notEqual: return !isOne
    default: return false
    }
  }

  /// Texts: compared without regard to case or accents.
  private static func compareText(_ actual: String?, _ test: ArchiveTest) -> Bool {
    let wanted = values(of: test.value).compactMap(word(of:)).map(folded)
    guard let actual else { return test.comparison == .notEqual }
    let text = folded(actual)
    switch test.comparison {
    case .equal, .in: return wanted.contains(text)
    case .notEqual: return !wanted.contains(text)
    case .contains: return wanted.contains { text.contains($0) }
    case .matches: return wanted.contains { glob($0, matches: text) }
    default: return false
    }
  }

  private static func compareElapsed(since date: Date?, _ test: ArchiveTest, now: Date) -> Bool {
    guard let date, case .duration(let duration) = test.value else { return false }
    let elapsed = now.timeIntervalSince(date)
    switch test.comparison {
    case .atLeast: return elapsed >= duration.seconds
    case .atMost: return elapsed <= duration.seconds
    default: return false
    }
  }

  private static func compareDay(_ date: Date?, _ test: ArchiveTest, calendar: Calendar) -> Bool {
    guard let date, case .date(let day) = test.value, let start = day.start(in: calendar) else {
      return false
    }
    switch test.comparison {
    case .before: return date < start
    case .after:
      guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
      return date >= next
    default: return false
    }
  }

  static func isFolder(_ folder: String, under path: String) -> Bool {
    let base = expanded(path)
    let folder = expanded(folder)
    return folder == base || folder.hasPrefix(base.hasSuffix("/") ? base : base + "/")
  }

  private static func expanded(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return (expanded as NSString).standardizingPath
  }

  /// `*` any characters, `?` one; nothing else is special.
  static func glob(_ pattern: String, matches text: String) -> Bool {
    let pattern = Array(pattern)
    let text = Array(text)
    var p = 0
    var t = 0
    var star: Int?
    var mark = 0
    while t < text.count {
      if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
        p += 1
        t += 1
      } else if p < pattern.count, pattern[p] == "*" {
        star = p
        mark = t
        p += 1
      } else if let star {
        p = star + 1
        mark += 1
        t = mark
      } else {
        return false
      }
    }
    while p < pattern.count, pattern[p] == "*" { p += 1 }
    return p == pattern.count
  }
}
