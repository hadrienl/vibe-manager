import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private struct StepClock: SessionClock {
  let date: Date
  func now() -> Date { date }
}

private func stored(_ text: String, activatedAt: Date, state: StoredArchiveRule.State = .active)
  -> StoredArchiveRule
{
  StoredArchiveRule(
    text: text, state: state, sentence: "", agent: "claude", createdAt: activatedAt,
    activatedAt: activatedAt)
}

@Suite("Running archive rules at their times (#405)")
struct ArchiveRuleSchedulerTests {
  let calendar = parisCalendar()
  let start = paris("2026-10-21 12:00")
  let friday = #"rule "Vertes" archive done sessions where badge.color = #1E7F4D on weekly friday at 18:00"#

  @Test("On time, then nothing until the next time")
  func onTime() {
    let rule = stored(friday, activatedAt: start)
    #expect(ArchiveRuleScheduler.decision(for: rule, now: paris("2026-10-23 17:59"), calendar: calendar) == .none)
    #expect(
      ArchiveRuleScheduler.decision(for: rule, now: paris("2026-10-23 18:00"), calendar: calendar)
        == .run(due: paris("2026-10-23 18:00"), isCatchUp: false))
    var handled = rule
    handled.lastHandled = paris("2026-10-23 18:00")
    #expect(ArchiveRuleScheduler.decision(for: handled, now: paris("2026-10-29 09:00"), calendar: calendar) == .none)
  }

  @Test("A rule kept before the summary was asked about summarizes; one that said no does not")
  func summarizesByDefault() throws {
    var rule = stored(friday, activatedAt: start)
    rule.summarizes = false
    let data = try JSONEncoder().encode(rule)
    #expect(try JSONDecoder().decode(StoredArchiveRule.self, from: data).summarizes == false)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["summary"] as? Bool == false)
    object["summary"] = nil
    let older = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(StoredArchiveRule.self, from: older).summarizes)
  }

  @Test("Times missed are caught up once, standing for the last one; or passed with no catch-up")
  func catchUp() {
    let rule = stored(friday, activatedAt: start)
    #expect(
      ArchiveRuleScheduler.decision(for: rule, now: paris("2026-11-09 08:00"), calendar: calendar)
        == .run(due: paris("2026-11-06 18:00"), isCatchUp: true))
    let strict = stored(friday + " no catch-up", activatedAt: start)
    #expect(
      ArchiveRuleScheduler.decision(for: strict, now: paris("2026-11-09 08:00"), calendar: calendar)
        == .pass(due: paris("2026-11-06 18:00")))
  }

  @Test("A paused rule, or one that no longer reads, never runs")
  func pausedAndUnreadable() {
    let now = paris("2026-10-23 18:00")
    #expect(ArchiveRuleScheduler.decision(for: stored(friday, activatedAt: start, state: .paused), now: now, calendar: calendar) == .none)
    #expect(ArchiveRuleScheduler.decision(for: stored("rule \"x\" archive", activatedAt: start), now: now, calendar: calendar) == .none)
  }

  @Test("Two copies of the application claim the same time once")
  func claimedOnce() async throws {
    let store = InMemoryArchiveRuleStore(ArchiveRuleSet(rules: [stored(friday, activatedAt: start)]))
    let clock = StepClock(date: paris("2026-10-23 18:00"))
    let first = ArchiveRuleScheduler(store: store, clock: clock, calendar: { parisCalendar() })
    let second = ArchiveRuleScheduler(store: store, clock: clock, calendar: { parisCalendar() })
    async let one = first.claimDueRuns()
    async let two = second.claimDueRuns()
    let runs = try await one + two
    #expect(runs.count == 1)
    #expect(runs.first?.isTrial == false)
  }

  @Test("A rule on trial runs, marked as such")
  func trial() async throws {
    let store = InMemoryArchiveRuleStore(
      ArchiveRuleSet(rules: [stored(friday, activatedAt: start, state: .trial)]))
    let runs = try await ArchiveRuleScheduler(
      store: store, clock: StepClock(date: paris("2026-10-23 18:00")),
      calendar: { parisCalendar() }
    ).claimDueRuns()
    #expect(runs.map(\.isTrial) == [true])
  }
}

@Suite("The test bench (#405)")
struct ArchiveRuleBenchTests {
  let calendar = parisCalendar()
  let start = paris("2026-10-21 12:00")
  let end = paris("2027-01-21 12:00")

  func objective() throws -> ArchiveRuleDocument {
    try ArchiveRuleParser.parse(objectiveRules)
  }

  @Test("Red on the 15th at 18:00, green on Fridays at 18:00, and nothing else")
  func objectiveTimeline() throws {
    let red = BenchSession.done("Red", at: paris("2026-10-20 10:00")) { $0.colorHex = "#B42318" }
    let brick = BenchSession.done("Brick", at: paris("2026-10-20 10:00")) { $0.colorHex = "#9B2C1F" }
    let redRunning = BenchSession.done("Red running", at: paris("2026-10-20 10:00")) {
      $0.colorHex = "#B42318"
      $0.runningUntil = paris("2026-11-16 09:00")
    }
    let redIcon = BenchSession.done("Red icon", at: paris("2026-10-20 10:00")) {
      $0.colorHex = "#B42318"
      $0.showsProjectIcon = true
    }
    var redLater = BenchSession.done("Red waiting", at: paris("2026-10-20 10:00")) {
      $0.colorHex = "#B42318"
    }
    redLater.history.removeLast()
    redLater.move(to: .waiting, at: paris("2026-10-20 10:00"))
    redLater.move(to: .done, at: paris("2026-11-20 10:00"))
    let greenBefore = BenchSession.done("Green 17:59", at: paris("2026-10-23 17:59")) {
      $0.colorHex = "#1E7F4D"
    }
    let greenAfter = BenchSession.done("Green 18:01", at: paris("2026-10-23 18:01")) {
      $0.colorHex = "#1E7F4D"
    }
    var greenUnarchived = BenchSession.done("Green unarchived", at: paris("2026-10-10 10:00")) {
      $0.colorHex = "#1E7F4D"
    }
    greenUnarchived.move(to: .archived, at: paris("2026-10-15 10:00"))
    greenUnarchived.move(to: .done, at: paris("2026-10-20 10:00"), cause: .unarchive)

    let sessions = [red, brick, redRunning, redIcon, redLater, greenBefore, greenAfter, greenUnarchived]
    let outcome = ArchiveRuleBench.run(
      try objective(), sessions: sessions, from: start, through: end, calendar: calendar)

    #expect(outcome.archivals[red.id]?.date == paris("2026-11-15 18:00"))
    #expect(outcome.archivals[brick.id] == nil)
    #expect(outcome.skips[redRunning.id]?.first?.verdict == .running)
    #expect(outcome.archivals[redRunning.id]?.date == paris("2026-12-15 18:00"))
    #expect(outcome.archivals[redIcon.id] == nil)
    #expect(outcome.archivals[redLater.id]?.date == paris("2026-12-15 18:00"))
    #expect(outcome.archivals[greenBefore.id]?.date == paris("2026-10-23 18:00"))
    #expect(outcome.archivals[greenAfter.id]?.date == paris("2026-10-30 18:00"))
    #expect(outcome.archivals[greenUnarchived.id] == nil)
    #expect(outcome.skips[greenUnarchived.id]?.first?.verdict == .unarchived)
  }

  @Test("The Mac off over the holidays: one catch-up when it comes back")
  func offPeriod() throws {
    let green = BenchSession.done("Green", at: paris("2026-12-20 10:00")) { $0.colorHex = "#1E7F4D" }
    let off = BenchOffPeriod(
      interval: DateInterval(start: paris("2026-12-24 12:00"), end: paris("2027-01-04 09:00")))
    let outcome = ArchiveRuleBench.run(
      try objective(), sessions: [green], from: start, through: end, calendar: calendar,
      off: [off])
    #expect(outcome.archivals[green.id]?.date == paris("2027-01-04 09:00"))
    let catchUps = outcome.runs.filter { if case .catchUp = $0.kind { true } else { false } }
    // One for the reds (the 15th of December was before) — none — and one for the greens.
    #expect(catchUps.count == 1)
    #expect(catchUps.first?.due == paris("2027-01-01 18:00"))
    #expect(outcome.runs.contains { $0.kind == .missed && $0.due == paris("2026-12-25 18:00") })
  }

  @Test("The bench and the real runs give the same dates on the same sessions")
  func sameAsTheScheduler() async throws {
    let document = try objective()
    let sessions = ArchiveBenchCases.make(for: document, start: start, calendar: calendar)
    let outcome = ArchiveRuleBench.run(
      document, sessions: sessions, from: start, through: end, calendar: calendar)

    // The real scheduler, ticked at every time a rule is due, over the same sessions.
    let store = InMemoryArchiveRuleStore(
      ArchiveRuleSet(
        rules: document.rules.map {
          stored(ArchiveRulePrinter.text(of: $0), activatedAt: start)
        }))
    var archived: [SessionID: Date] = [:]
    var times: Set<Date> = []
    for rule in document.rules {
      for time in rule.schedule.occurrences(
        from: start, through: end, calendar: calendar, activatedAt: start)
      {
        times.insert(time)
      }
    }
    for now in times.sorted() {
      let runs = try await ArchiveRuleScheduler(
        store: store, clock: StepClock(date: now), calendar: { parisCalendar() }
      ).claimDueRuns()
      var candidates = sessions.filter { archived[$0.id] == nil }.map { $0.candidate(at: now) }
      for run in runs {
        let plan = ArchiveRuleEvaluation.plan(
          rule: run.rule, protections: document.protections, candidates: candidates, now: now,
          calendar: calendar)
        for id in plan.archived { archived[id] = now }
        candidates.removeAll { plan.archived.contains($0.id) }
      }
    }
    #expect(archived == outcome.archivals.mapValues(\.date))
    #expect(!archived.isEmpty)
  }

  @Test("Each field of the rule has a session that matches, one that misses, one on the edge")
  func casesCoverTheFields() throws {
    let document = try ArchiveRuleParser.parse(richRules)
    let sessions = ArchiveBenchCases.make(for: document, start: start, calendar: calendar)
    #expect((20...ArchiveBenchCases.maximumCount).contains(sessions.count))
    let outcome = ArchiveRuleBench.run(
      document, sessions: sessions, from: start, through: end, calendar: calendar)
    #expect(!outcome.archivals.isEmpty)
    #expect(outcome.archivals.count < sessions.count)
  }

  @Test("40 sessions over 12 months in well under a second")
  func fast() throws {
    let document = try ArchiveRuleParser.parse(objectiveRules + "\n" + richRules)
    let sessions = ArchiveBenchCases.make(for: document, start: start, calendar: calendar)
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      _ = ArchiveRuleBench.run(
        document, sessions: sessions, from: start, through: paris("2027-10-21 12:00"),
        calendar: calendar)
    }
    #expect(elapsed < .seconds(1))
  }
}
