import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

let objectiveRules = """
  rule "Rouges, le 15"
    archive done sessions where badge.color = #B42318
    on monthly 15 at 18:00

  rule "Vertes, en fin de semaine"
    archive done sessions where badge.color = #1E7F4D
    on weekly friday at 18:00
  """

let richRules = """
  protect where project = "client-x" or badge.symbol = "pin.fill"

  // The last Friday's clean-up.
  rule "Ménage du dernier vendredi"
    archive done sessions where
      done.since >= 3d
      and (agent = codex or git.branch ~ "spike/*")
      and not git.dirty
      and coordination != coordinator
    on monthly last friday at 17:30
    limit 30

  rule "Enfants finis"
    archive done sessions where coordination = child and done.since >= 2h
    on continuously
  """

func parisCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
  calendar.locale = Locale(identifier: "en_US")
  return calendar
}

func paris(_ text: String) -> Date {
  let formatter = DateFormatter()
  formatter.calendar = parisCalendar()
  formatter.timeZone = parisCalendar().timeZone
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyy-MM-dd HH:mm"
  return formatter.date(from: text)!
}

@Suite("Reading and writing the language of archive rules (#405)")
struct ArchiveRuleParserTests {
  @Test("The sentence of the objective reads as two rules, red on the 15th and green on Fridays")
  func objective() throws {
    let document = try ArchiveRuleParser.parse(objectiveRules)
    #expect(
      document.rules == [
        ArchiveRule(
          name: "Rouges, le 15",
          condition: .test(ArchiveTest(.badgeColor, .equal, .color("#B42318"))),
          schedule: .monthly([.number(15)], ArchiveTime(hour: 18, minute: 0))),
        ArchiveRule(
          name: "Vertes, en fin de semaine",
          condition: .test(ArchiveTest(.badgeColor, .equal, .color("#1E7F4D"))),
          schedule: .weekly([.friday], ArchiveTime(hour: 18, minute: 0))),
      ])
    #expect(document.protections.isEmpty)
  }

  @Test("A richer text: a protection, groups, negation, a limit, continuously")
  func rich() throws {
    let document = try ArchiveRuleParser.parse(richRules)
    #expect(document.protections.count == 1)
    #expect(document.rules.map(\.name) == ["Ménage du dernier vendredi", "Enfants finis"])
    #expect(document.rules[0].limit == 30)
    #expect(
      document.rules[0].schedule
        == .monthly([.weekday(.last, .friday)], ArchiveTime(hour: 17, minute: 30)))
    #expect(document.rules[1].schedule == .continuously)
    guard case .all(let parts) = document.rules[0].condition else {
      Issue.record("Expected a conjunction")
      return
    }
    #expect(parts.count == 4)
    #expect(parts[2] == .not(.test(ArchiveTest(.gitDirty, .isTrue, .none))))
  }

  @Test(
    "What is printed reads back as the same document",
    arguments: [objectiveRules, richRules]
      + ArchiveField.allCases.map {
        "rule \"r\" archive done sessions where \($0.example) on daily at 18:00"
      }
      + [
        #"rule "a" archive done sessions where not (name = "x" or name = "y") on daily at 09:00"#,
        #"rule "b" archive done sessions where name = "x" and (name = "y" and name = "z") on weekdays at 08:15"#,
        #"rule "c" archive done sessions on every 3d at 08:00 no catch-up"#,
        #"rule "d" archive done sessions on every 6h"#,
        #"rule "e" archive done sessions on monthly 1, 15, last day, first monday at 23:59"#,
        #"rule "f \"quoted\" \\ name" archive done sessions on weekly monday, thursday at 09:00"#,
      ]
  )
  func roundTrip(text: String) throws {
    let document = try ArchiveRuleParser.parse(text)
    let printed = ArchiveRulePrinter.text(of: document)
    #expect(try ArchiveRuleParser.parse(printed) == document)
    #expect(ArchiveRulePrinter.text(of: try ArchiveRuleParser.parse(printed)) == printed)
  }

  @Test(
    "A text that is not a rule is refused with its line, column and an English message",
    arguments: [
      (
        "rule \"a\"\n  archive done sessions where colour = #B42318 on daily at 18:00", 2, 31,
        "field"
      ),
      (
        "rule \"a\" archive done sessions where badge.color = #B4231 on daily at 18:00", 1, 52,
        "#RRGGBB"
      ),
      (
        "rule \"a\" archive done sessions where badge.color contains #B42318 on daily at 18:00", 1,
        50, "takes"
      ),
      (
        "rule \"a\" archive done sessions where name = spike on daily at 18:00", 1, 45,
        "text in quotes"
      ),
      ("rule \"a\" archive waiting sessions on daily at 18:00", 1, 18, "only done sessions"),
      ("rule \"a\" archive done sessions on daily at 25:00", 1, 44, "HH:MM"),
      ("rule \"a\" archive done sessions on monthly 32 at 18:00", 1, 43, "1 to 31"),
      ("rule \"a\" archive done sessions on every 6h at 08:00", 1, 35, "days or weeks"),
      ("rule \"a\" archive done sessions on every 5m", 1, 41, "15m"),
      ("rule \"a\" archive done sessions on continuously no catch-up", 1, 35, "continuously"),
      (
        "rule \"a\" archive done sessions on daily at 18:00\nrule \"A\" archive done sessions on daily at 19:00",
        2, 1, "Two rules"
      ),
      (
        "rule \"a\" archive done sessions where name ~ \"^spike\" on daily at 18:00", 1, 45,
        "regular expression"
      ),
      ("", 1, 1, "no rule"),
      (
        "rule \"a\" archive done sessions where name = \"x on daily at 18:00", 1, 45, "never closed"
      ),
    ] as [(String, Int, Int, String)]
  )
  func problems(text: String, line: Int, column: Int, words: String) {
    do {
      _ = try ArchiveRuleParser.parse(text)
      Issue.record("Expected a problem")
    } catch {
      #expect(error.line == line)
      #expect(error.column == column)
      #expect(error.message.contains(words), "\(error.message)")
    }
  }
}

@Suite("When archive rules run (#405)")
struct ArchiveScheduleTests {
  let calendar = parisCalendar()
  let activated = paris("2026-10-01 00:00")

  func next(_ schedule: ArchiveSchedule, after text: String) -> Date? {
    schedule.nextOccurrence(after: paris(text), calendar: calendar, activatedAt: activated)
  }

  @Test("The 15th of every month at 18:00, and Fridays at 18:00")
  func objective() {
    let six = ArchiveTime(hour: 18, minute: 0)
    #expect(
      next(.monthly([.number(15)], six), after: "2026-10-21 12:00") == paris("2026-11-15 18:00"))
    #expect(
      next(.monthly([.number(15)], six), after: "2026-11-15 17:59") == paris("2026-11-15 18:00"))
    #expect(
      next(.monthly([.number(15)], six), after: "2026-11-15 18:00") == paris("2026-12-15 18:00"))
    #expect(next(.weekly([.friday], six), after: "2026-10-21 12:00") == paris("2026-10-23 18:00"))
    #expect(next(.weekly([.friday], six), after: "2026-10-23 18:00") == paris("2026-10-30 18:00"))
  }

  @Test("A day the month does not have falls on its last day")
  func shortMonths() {
    let time = ArchiveTime(hour: 23, minute: 0)
    #expect(
      next(.monthly([.number(31)], time), after: "2026-04-01 00:00") == paris("2026-04-30 23:00"))
    #expect(
      next(.monthly([.number(30)], time), after: "2027-02-01 00:00") == paris("2027-02-28 23:00"))
    #expect(
      next(.monthly([.lastDay], time), after: "2028-02-01 00:00") == paris("2028-02-29 23:00"))
  }

  @Test("The nth day of the week of a month")
  func ordinals() {
    let time = ArchiveTime(hour: 17, minute: 30)
    #expect(
      next(.monthly([.weekday(.last, .friday)], time), after: "2026-10-01 00:00")
        == paris("2026-10-30 17:30"))
    #expect(
      next(.monthly([.weekday(.first, .monday)], time), after: "2026-10-06 00:00")
        == paris("2026-11-02 17:30"))
    #expect(
      next(.monthly([.weekday(.fourth, .thursday)], time), after: "2026-11-01 00:00")
        == paris("2026-11-26 17:30"))
  }

  @Test("A time the clocks skip is the first that exists; a time they repeat runs once")
  func daylightSaving() {
    // 2027-03-28: 02:00 jumps to 03:00 in Paris. 2026-10-25: 03:00 goes back to 02:00.
    let skipped = next(.daily(ArchiveTime(hour: 2, minute: 30)), after: "2027-03-28 00:00")
    #expect(skipped == paris("2027-03-28 03:00"))
    let repeated = next(.daily(ArchiveTime(hour: 2, minute: 30)), after: "2026-10-25 00:00")
    let following = repeated.flatMap {
      ArchiveSchedule.daily(ArchiveTime(hour: 2, minute: 30)).nextOccurrence(
        after: $0, calendar: calendar, activatedAt: activated)
    }
    #expect(following == paris("2026-10-26 02:30"))
  }

  @Test("Monday to Friday skips the weekend")
  func weekdays() {
    #expect(
      next(.weekdays(ArchiveTime(hour: 18, minute: 0)), after: "2026-10-23 18:00")
        == paris("2026-10-26 18:00"))
  }

  @Test("`every` counts from when the rule was turned on")
  func every() {
    #expect(
      next(.every(ArchiveDuration(6, .hours), nil), after: "2026-10-01 07:00")
        == paris("2026-10-01 12:00"))
    let threeDays = ArchiveSchedule.every(
      ArchiveDuration(3, .days), ArchiveTime(hour: 8, minute: 0))
    #expect(next(threeDays, after: "2026-09-01 00:00") == paris("2026-10-01 08:00"))
    #expect(next(threeDays, after: "2026-10-01 08:00") == paris("2026-10-04 08:00"))
    #expect(next(.continuously, after: "2026-10-01 08:00") == nil)
  }

  @Test("The latest time at or before a moment, for a run that comes late")
  func latest() {
    let schedule = ArchiveSchedule.weekly([.friday], ArchiveTime(hour: 18, minute: 0))
    let latest = schedule.latestOccurrence(
      atOrBefore: paris("2026-11-02 09:00"), since: paris("2026-10-20 00:00"), calendar: calendar,
      activatedAt: activated)
    #expect(latest == paris("2026-10-30 18:00"))
  }
}

@Suite("Which sessions a rule archives (#405)")
struct ArchiveRuleEvaluationTests {
  let calendar = parisCalendar()
  let now = paris("2026-11-15 18:00")

  func done(
    _ name: String = "Task", color: String = "#B42318", doneAt: String = "2026-11-01 10:00",
    icon: Bool = false
  ) -> WorkSession {
    var session = WorkSession(
      name: name,
      appearance: SessionAppearance(
        symbolName: "terminal", colorHex: color,
        iconID: icon ? SessionIconID(sha256: String(repeating: "a", count: 64)) : nil),
      status: .closed, createdAt: paris("2026-10-01 09:00"), updatedAt: paris("2026-10-01 09:00"),
      closedAt: paris("2026-10-01 09:00"),
      statusHistory: .created(in: .todo, at: paris("2026-10-01 09:00")),
      infersStartedAt: false)
    try? session.setTaskStatus(.done, at: paris(doneAt), cause: .user)
    return session
  }

  func rule(_ text: String) throws -> ArchiveRuleDocument {
    try ArchiveRuleParser.parse(text)
  }

  func verdict(_ candidate: ArchiveCandidate, _ text: String) throws -> ArchiveVerdict {
    let document = try rule(text)
    return ArchiveRuleEvaluation.verdict(
      of: candidate, rule: document.rules[0], protections: document.protections, now: now,
      calendar: calendar)
  }

  @Test("Red exactly: not brick red, not a project icon, not a session still running")
  func objective() throws {
    let text = objectiveRules
    #expect(try verdict(ArchiveCandidate(session: done()), text) == .archive)
    if case .notMatching = try verdict(ArchiveCandidate(session: done(color: "#9B2C1F")), text) {
    } else {
      Issue.record("Brick red matched")
    }
    if case .notMatching = try verdict(ArchiveCandidate(session: done(icon: true)), text) {
    } else {
      Issue.record("A project icon matched")
    }
    #expect(try verdict(ArchiveCandidate(session: done(), isRunning: true), text) == .running)
  }

  @Test("A session not in Done is never archived")
  func onlyDone() throws {
    let waiting = WorkSession(name: "Waiting", status: .closed, taskStatus: .waiting)
    #expect(try verdict(ArchiveCandidate(session: waiting), objectiveRules) == .notDone)
  }

  @Test("A session the user took out of the archive is skipped until it leaves Done and comes back")
  func unarchived() throws {
    var session = done()
    try session.archive(at: paris("2026-11-02 10:00"), cause: .user)
    try session.restore(at: paris("2026-11-03 10:00"), cause: .unarchive)
    #expect(try verdict(ArchiveCandidate(session: session), objectiveRules) == .unarchived)
    try session.setTaskStatus(.doing, at: paris("2026-11-04 10:00"), cause: .user)
    try session.setTaskStatus(.done, at: paris("2026-11-05 10:00"), cause: .user)
    #expect(try verdict(ArchiveCandidate(session: session), objectiveRules) == .archive)
  }

  @Test("A protection wins over every rule, and one that cannot be told protects")
  func protections() throws {
    let text = """
      protect where project = "client-x"
      protect where git.dirty
      rule "All" archive done sessions on daily at 18:00
      """
    if case .protected = try verdict(
      ArchiveCandidate(session: done(), project: "Client-X", isDirty: false), text)
    {
    } else {
      Issue.record("Not protected by its project")
    }
    if case .protected = try verdict(ArchiveCandidate(session: done(), project: "client-xy"), text)
    {
    } else {
      Issue.record("An unknown Git state did not protect")
    }
    #expect(
      try verdict(ArchiveCandidate(session: done(), project: "client-xy", isDirty: false), text)
        == .archive)
  }

  @Test("Done counts from the last time in Done, and texts ignore case and accents")
  func doneSinceAndTexts() throws {
    var session = done("Écrire le SPIKE", doneAt: "2026-11-10 18:00")
    let text =
      #"rule "a" archive done sessions where done.since >= 3d and name contains "spike" on daily at 18:00"#
    #expect(try verdict(ArchiveCandidate(session: session), text) == .archive)
    try session.setTaskStatus(.doing, at: paris("2026-11-13 18:00"), cause: .user)
    try session.setTaskStatus(.done, at: paris("2026-11-13 18:01"), cause: .user)
    if case .notMatching(let part) = try verdict(ArchiveCandidate(session: session), text) {
      #expect(
        part == .test(ArchiveTest(.doneSince, .atLeast, .duration(ArchiveDuration(3, .days)))))
    } else {
      Issue.record("A session done again was archived")
    }
  }

  @Test("Patterns know * and ? only")
  func globs() {
    #expect(ArchiveRuleEvaluation.glob("spike/*", matches: "spike/cache"))
    #expect(!ArchiveRuleEvaluation.glob("spike/*", matches: "release/spike"))
    #expect(ArchiveRuleEvaluation.glob("v?.?", matches: "v1.2"))
    #expect(ArchiveRuleEvaluation.isFolder("/Users/a/Code/client/x", under: "/Users/a/Code/client"))
    #expect(
      !ArchiveRuleEvaluation.isFolder("/Users/a/Code/client-xy", under: "/Users/a/Code/client"))
  }

  @Test("A limit archives the longest done first, and the rest wait")
  func limit() throws {
    let document = try rule(#"rule "a" archive done sessions on daily at 18:00 limit 2"#)
    let sessions = ["2026-11-03 10:00", "2026-11-01 10:00", "2026-11-02 10:00"].map {
      ArchiveCandidate(session: done(doneAt: $0))
    }
    let plan = ArchiveRuleEvaluation.plan(
      rule: document.rules[0], protections: [], candidates: sessions, now: now, calendar: calendar)
    #expect(plan.archived == [sessions[1].id, sessions[2].id])
    #expect(plan.skipped == [sessions[0].id: .overLimit])
  }
}

@Suite("What a rule is said to do (#405)")
struct ArchiveRuleExplanationTests {
  /// Times are formatted with a narrow no-break space before AM and PM.
  func sentence(of rule: ArchiveRule) -> String {
    explanation.sentence(of: rule).replacingOccurrences(of: "\u{202F}", with: " ")
  }

  let explanation = ArchiveRuleExplanation(
    vocabulary: ArchiveRuleVocabulary(
      colorNames: ["#B42318": "Red", "#1E7F4D": "Green"], agentNames: ["codex": "Codex"]),
    calendar: parisCalendar(), locale: Locale(identifier: "en_US"))

  @Test("The objective's two rules")
  func objective() throws {
    let document = try ArchiveRuleParser.parse(objectiveRules)
    #expect(
      sentence(of: document.rules[0])
        == "On day 15 of every month at 6:00 PM, archives the done sessions where the badge is Red (#B42318)."
    )
    #expect(
      sentence(of: document.rules[1])
        == "Every Friday at 6:00 PM, archives the done sessions where the badge is Green (#1E7F4D)."
    )
  }

  @Test("Every form of the grammar is said in words")
  func everyForm() throws {
    let document = try ArchiveRuleParser.parse(richRules)
    #expect(
      explanation.sentence(of: document.protections[0])
        == "Never a session where the group is “client-x” or the badge shows pin.fill, whatever the rule."
    )
    #expect(
      sentence(of: document.rules[0])
        == "On the last Friday of every month at 5:30 PM, archives the done sessions where it has been "
        + "done for at least 3 days, (the agent is Codex or the branch matches “spike/*”), the folder "
        + "has no uncommitted changes, and the session coordinates no other. At most 30 sessions "
        + "each time, the longest done first.")
    for field in ArchiveField.allCases {
      let text = "rule \"r\" archive done sessions where \(field.example) on daily at 18:00"
      let rule = try ArchiveRuleParser.parse(text).rules[0]
      #expect(!explanation.sentence(of: rule).isEmpty)
      if field.keyword.contains(".") {
        #expect(!explanation.sentence(of: rule).contains(field.keyword), "\(field.keyword)")
      }
    }
  }
}

@Suite("One definition of the language of archive rules (#405)")
struct ArchiveRuleGrammarTests {
  private var repositoryDocument: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "docs/archive-rules.md")
  }

  @Test("docs/archive-rules.md is the text the code gives, the one the agent is given")
  func repositoryDocumentIsTheCodes() throws {
    if ProcessInfo.processInfo.environment["VIBE_WRITE_ARCHIVE_RULES_DOC"] == "1" {
      try Data(ArchiveRuleGrammar.document.utf8).write(to: repositoryDocument)
    }
    let written = try String(contentsOf: repositoryDocument, encoding: .utf8)
    #expect(written == ArchiveRuleGrammar.document)
    #expect(
      ArchiveRuleInstructions.systemPrompt(context: .sample).contains(ArchiveRuleGrammar.language))
  }

  @Test("The examples given are rules the parser reads")
  func examplesParse() throws {
    let document = try ArchiveRuleParser.parse(ArchiveRuleGrammar.examples)
    #expect(document.rules.count == 4)
    #expect(document.protections.count == 1)
  }

  @Test("Every field of the code is in the reference")
  func everyField() {
    for field in ArchiveField.allCases {
      #expect(ArchiveRuleGrammar.fields.contains("| `\(field.keyword)` |"))
    }
  }
}
