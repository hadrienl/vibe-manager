import Foundation
import VibeDomain

/// The made-up sessions of the test bench, built from the rules tried (#405): for every field the
/// rules and the protections read, one session that matches, one that just misses and one on the
/// edge; and the traps every rule must get right — something running, a session the user took out
/// of the archive, a badge showing the project's icon, the other columns, a session done just
/// before and just after its time.
public enum ArchiveBenchCases {
  public static let maximumCount = 40

  public static func make(
    for document: ArchiveRuleDocument, start: Date, calendar: Calendar,
    palette: [ArchiveRuleContext.Color] = []
  ) -> [BenchSession] {
    var builder = Builder(start: start, calendar: calendar, palette: palette)
    let day: (Int) -> Date = { offset in
      calendar.date(byAdding: .day, value: offset, to: start) ?? start
    }
    let rules = document.rules
    let base = builder.matching(rules.first?.condition)
    // The traps, on a session every rule would otherwise archive.
    builder.add(base, name: String(localized: "Matches every rule", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { _ in }
    builder.add(base, name: String(localized: "Its agent still runs", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
      session.runningUntil = day(6)
    }
    builder.add(base, name: String(localized: "Unarchived by you", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
      session.move(to: .archived, at: day(-2), cause: .user)
      session.move(to: .done, at: day(2), cause: .unarchive)
    }
    builder.add(base, name: String(localized: "Waiting, done later", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
      session.history.removeLast()
      session.move(to: .waiting, at: day(-1))
      session.move(to: .done, at: day(20))
    }
    for column in [SessionTaskStatus.todo, .doing, .waiting] {
      let name =
        switch column {
        case .todo: String(localized: "Stays in To Do", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")
        case .doing: String(localized: "Stays In Progress", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")
        default: String(localized: "Stays Waiting", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")
        }
      builder.add(base, name: name) { session in
        session.history.removeLast()
        session.move(to: column, at: day(-1))
      }
    }
    // Around each rule's time: done a minute before and a minute after.
    for rule in rules {
      guard
        let first = rule.schedule.nextOccurrence(after: start, calendar: calendar, activatedAt: start)
      else { continue }
      builder.add(base, name: String(localized: "Done a minute before “\(rule.name)”", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
        session.history.removeLast()
        session.move(to: .done, at: first.addingTimeInterval(-60))
      }
      builder.add(base, name: String(localized: "Done a minute after “\(rule.name)”", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
        session.history.removeLast()
        session.move(to: .done, at: first.addingTimeInterval(60))
      }
    }
    // Every field read, three ways.
    var tests: [ArchiveTest] = []
    for condition in rules.compactMap(\.condition) + document.protections.map(\.condition) {
      tests += condition.tests
    }
    for test in tests {
      for variant in builder.variants(of: test) {
        builder.add(base, name: variant.name, configure: variant.configure)
      }
    }
    return Array(builder.sessions.prefix(maximumCount))
  }

  struct Variant {
    let name: String
    let configure: (inout BenchSession) -> Void
  }

  struct Builder {
    let start: Date
    let calendar: Calendar
    let palette: [ArchiveRuleContext.Color]
    var sessions: [BenchSession] = []
    var names: Set<String> = []

    init(start: Date, calendar: Calendar, palette: [ArchiveRuleContext.Color]) {
      self.start = start
      self.calendar = calendar
      self.palette = palette
    }

    func day(_ offset: Int) -> Date {
      calendar.date(byAdding: .day, value: offset, to: start) ?? start
    }

    mutating func add(
      _ base: BenchSession, name: String, configure: (inout BenchSession) -> Void
    ) {
      guard !names.contains(name), sessions.count < ArchiveBenchCases.maximumCount else { return }
      names.insert(name)
      var session = base
      session = BenchSession(
        name: name, colorHex: base.colorHex, symbolName: base.symbolName,
        showsProjectIcon: base.showsProjectIcon, project: base.project, folder: base.folder,
        agent: base.agent, model: base.model, ticket: base.ticket, branch: base.branch,
        isDirty: base.isDirty, cleanAt: base.cleanAt, coordination: base.coordination,
        createdAt: base.createdAt, runningUntil: base.runningUntil, history: base.history)
      configure(&session)
      sessions.append(session)
    }

    /// A session done a week ago that matches `condition` as far as can be told: each test made
    /// true, the first part of an `or`.
    func matching(_ condition: ArchiveCondition?) -> BenchSession {
      var session = BenchSession.done("", at: day(-7), createdAt: day(-30))
      session.project = "project"
      session.folder = "/Users/me/Code/project"
      for test in condition?.requiredTests ?? [] {
        Self.satisfy(test, in: &session, start: start, calendar: calendar)
      }
      return session
    }

    static func satisfy(
      _ test: ArchiveTest, in session: inout BenchSession, start: Date, calendar: Calendar
    ) {
      let first: ArchiveValue = {
        if case .list(let items) = test.value, let first = items.first { return first }
        return test.value
      }()
      let wants = test.comparison != .notEqual
      switch (test.field, first) {
      case (.badgeColor, .color(let hex)):
        session.colorHex = wants ? hex : "#5E5CE6"
      case (.badgeSymbol, .text(let symbol)):
        session.symbolName = wants ? symbol : "terminal"
      case (.badgeKind, .word(let kind)):
        session.showsProjectIcon = (kind == "projectIcon") == wants
      case (.name, .text(let text)):
        session.name = wants ? Self.instance(of: text, comparison: test.comparison) : "Other"
      case (.project, .text(let text)):
        session.project = wants ? Self.instance(of: text, comparison: test.comparison) : "other"
      case (.folder, .text(let path)):
        session.folder = (path as NSString).expandingTildeInPath + "/app"
      case (.agent, .word(let agent)):
        session.agent = wants ? agent : (agent == "claude" ? "codex" : "claude")
      case (.model, .text(let text)):
        session.model = wants ? Self.instance(of: text, comparison: test.comparison) : "other"
      case (.ticket, _):
        session.ticket =
          test.comparison == .isTrue ? URL(string: "https://github.com/me/app/issues/1") : nil
      case (.ticketHost, .text(let host)):
        session.ticket = URL(string: "https://\(host)/me/app/issues/1")
      case (.gitBranch, .text(let text)):
        session.branch = wants ? Self.instance(of: text, comparison: test.comparison) : "main"
      case (.gitDirty, _):
        session.isDirty = true
      case (.coordination, .word(let role)):
        let target = wants ? role : (role == "none" ? "coordinator" : "none")
        session.coordination =
          target == "coordinator" ? .coordinator : target == "child" ? .child(of: SessionID()) : nil
      case (.doneSince, .duration(let duration)) where test.comparison == .atLeast:
        Self.redo(&session, doneAt: start.addingTimeInterval(-duration.seconds - 3600))
      case (.doneSince, .duration(let duration)):
        Self.redo(&session, doneAt: start.addingTimeInterval(-min(duration.seconds / 2, 3600)))
      case (.createdSince, .duration(let duration)) where test.comparison == .atLeast:
        session.createdAt = start.addingTimeInterval(-duration.seconds - 86_400)
        session.history[0] = SessionStatusChange(
          date: session.createdAt, from: nil, to: .todo, cause: .created)
        session.history[1] = SessionStatusChange(
          date: session.createdAt, from: .todo, to: .doing, cause: .launch)
      case (.reopened, .integer(let count)):
        for index in 0..<max(0, count) {
          let done = session.history.last?.date ?? start
          session.move(to: .doing, at: done.addingTimeInterval(Double(index + 1) * 60))
          session.move(to: .done, at: done.addingTimeInterval(Double(index + 1) * 60 + 30))
        }
      default:
        break
      }
    }

    static func redo(_ session: inout BenchSession, doneAt: Date) {
      session.history.removeLast()
      if let created = session.history.first?.date, created > doneAt {
        session.createdAt = doneAt.addingTimeInterval(-3600)
        session.history[0] = SessionStatusChange(
          date: session.createdAt, from: nil, to: .todo, cause: .created)
        session.history[1] = SessionStatusChange(
          date: session.createdAt, from: .todo, to: .doing, cause: .launch)
      }
      session.history.append(
        SessionStatusChange(date: doneAt, from: .doing, to: .done, cause: .user))
    }

    /// A text that answers to `pattern`: itself, or the pattern with its wildcards filled.
    static func instance(of pattern: String, comparison: ArchiveComparison) -> String {
      switch comparison {
      case .matches:
        return pattern.replacingOccurrences(of: "*", with: "cache")
          .replacingOccurrences(of: "?", with: "1")
      case .contains:
        return "Écrire le " + pattern.uppercased()
      default:
        return pattern
      }
    }

    /// One session that just misses `test`, one on its edge.
    func variants(of test: ArchiveTest) -> [Variant] {
      switch (test.field, test.value) {
      case (.badgeColor, _):
        return colorVariants(test)
      case (.badgeSymbol, _):
        return [
          Variant(name: String(localized: "Another symbol", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { $0.symbolName = "ladybug.fill" },
          Variant(name: String(localized: "The project's icon", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { $0.showsProjectIcon = true },
        ]
      case (.project, .text(let name)):
        return [
          Variant(name: String(localized: "Group “\(name)y”", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { $0.project = name + "y" },
          Variant(name: String(localized: "Group “\(name.uppercased())”", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { $0.project = name.uppercased() },
        ]
      case (.name, .text(let text)), (.model, .text(let text)), (.gitBranch, .text(let text)),
        (.ticketHost, .text(let text)):
        let near = String(text.dropLast()).isEmpty ? "x" : String(text.dropLast())
        return [
          Variant(name: String(localized: "Almost: “\(near)”", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
            Self.set(test.field, to: near, in: &session)
          },
          Variant(name: String(localized: "With accents and capitals", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
            Self.set(
              test.field,
              to: Self.instance(of: text, comparison: test.comparison).uppercased()
                .replacingOccurrences(of: "E", with: "É"), in: &session)
          },
        ]
      case (.folder, .text(let path)):
        let expanded = (path as NSString).expandingTildeInPath
        return [
          Variant(name: String(localized: "A folder beside it", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { $0.folder = expanded + "-other" },
          Variant(name: String(localized: "The folder itself", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { $0.folder = expanded },
        ]
      case (.agent, _):
        return [
          Variant(name: String(localized: "Another agent", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
            session.agent = session.agent == "codex" ? "claude" : "codex"
          }
        ]
      case (.ticket, _):
        return [
          Variant(name: String(localized: "With a ticket", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { $0.ticket = URL(string: "https://github.com/me/app/issues/2") },
          Variant(name: String(localized: "Without a ticket", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { $0.ticket = nil },
        ]
      case (.gitDirty, _):
        return [
          Variant(name: String(localized: "A clean folder", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { $0.isDirty = false },
          Variant(name: String(localized: "A folder with changes", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { $0.isDirty = true },
          Variant(name: String(localized: "Changes committed in a week", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
            session.isDirty = true
            session.cleanAt = day(7)
          },
        ]
      case (.coordination, _):
        return [
          Variant(name: String(localized: "A coordinator", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { $0.coordination = .coordinator },
          Variant(name: String(localized: "A coordinator's child", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { $0.coordination = .child(of: SessionID()) },
          Variant(name: String(localized: "Neither coordinator nor child", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { $0.coordination = nil },
        ]
      case (.doneSince, .duration(let duration)):
        return [
          Variant(name: String(localized: "Done an hour short of the time asked", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) {
            session in
            Self.redo(&session, doneAt: start.addingTimeInterval(-duration.seconds + 3600))
          },
          Variant(name: String(localized: "Done exactly the time asked", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
            Self.redo(&session, doneAt: start.addingTimeInterval(-duration.seconds))
          },
          Variant(name: String(localized: "Reopened, then done again", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
            session.move(to: .doing, at: start.addingTimeInterval(-3600))
            session.move(to: .done, at: start.addingTimeInterval(-1800))
          },
        ]
      case (.reopened, _):
        return [
          Variant(name: String(localized: "Never reopened", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { _ in },
          Variant(name: String(localized: "Reopened once", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
            session.move(to: .doing, at: start.addingTimeInterval(-7200))
            session.move(to: .done, at: start.addingTimeInterval(-3600))
          },
        ]
      case (.created, .date(let day)), (.activity, .date(let day)), (.closed, .date(let day)),
        (.done, .date(let day)), (.doneFirst, .date(let day)):
        guard let first = day.start(in: calendar) else { return [] }
        return [
          Variant(name: String(localized: "Done the day before", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
            Self.redo(&session, doneAt: first.addingTimeInterval(-12 * 3600))
          },
          Variant(name: String(localized: "Done on the day", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
            Self.redo(&session, doneAt: first.addingTimeInterval(12 * 3600))
          },
          Variant(name: String(localized: "Done the day after", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
            Self.redo(&session, doneAt: first.addingTimeInterval(36 * 3600))
          },
        ]
      default:
        return []
      }
    }

    func colorVariants(_ test: ArchiveTest) -> [Variant] {
      let wanted: [String] = {
        if case .list(let items) = test.value {
          return items.compactMap { if case .color(let hex) = $0 { hex } else { nil } }
        }
        if case .color(let hex) = test.value { return [hex] }
        return []
      }()
      var variants: [Variant] = []
      for hex in wanted {
        let near =
          palette.map(\.hex).filter { !wanted.contains($0) }
          .min { Self.distance($0, hex) < Self.distance($1, hex) }
          ?? Self.shifted(hex)
        variants.append(Variant(name: String(localized: "Badge \(near), close to \(hex)", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { $0.colorHex = near })
        variants.append(
          Variant(name: String(localized: "\(hex), but the project's icon", bundle: .module, comment: "The name of a made-up session of the archive rules' test bench.")) { session in
            session.colorHex = hex
            session.showsProjectIcon = true
          })
      }
      return variants
    }

    static func set(_ field: ArchiveField, to text: String, in session: inout BenchSession) {
      switch field {
      case .name: session.name = text
      case .model: session.model = text
      case .gitBranch: session.branch = text
      case .ticketHost: session.ticket = URL(string: "https://\(text)/me/app/issues/3")
      default: break
      }
    }

    static func components(_ hex: String) -> (Int, Int, Int) {
      let value = Int(hex.dropFirst(), radix: 16) ?? 0
      return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    static func distance(_ lhs: String, _ rhs: String) -> Int {
      let a = components(lhs)
      let b = components(rhs)
      return abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
    }

    /// A colour a few shades from `hex`: not the same colour.
    static func shifted(_ hex: String) -> String {
      let (red, green, blue) = components(hex)
      return String(
        format: "#%02X%02X%02X", max(red - 25, 0), min(green + 9, 255), min(blue + 7, 255))
    }
  }
}

extension ArchiveCondition {
  /// Every test it holds.
  var tests: [ArchiveTest] {
    switch self {
    case .test(let test): [test]
    case .not(let inner): inner.tests
    case .all(let parts), .any(let parts): parts.flatMap(\.tests)
    }
  }

  /// The tests a session must pass to match: all of an `and`, the first part of an `or`, none
  /// under a `not`.
  var requiredTests: [ArchiveTest] {
    switch self {
    case .test(let test): [test]
    case .not: []
    case .all(let parts): parts.flatMap(\.requiredTests)
    case .any(let parts): parts.first?.requiredTests ?? []
    }
  }
}
