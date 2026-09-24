import Foundation
import Testing

@testable import VibeDomain

@Suite("Adding usage up")
struct UsageAggregatorTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
  }()

  private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 9) -> Date {
    calendar.date(
      from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
  }

  private func run(
    _ session: SessionID = SessionID(), provider: String = "claude-code", model: String? = nil,
    kind: UsageRunKind = .start, from start: Date, to end: Date?, suspensions: [DateInterval] = []
  ) -> UsageRun {
    UsageRun(
      sessionID: session, providerID: provider, modelID: model, kind: kind, startedAt: start,
      endedAt: end, suspensions: suspensions)
  }

  @Test("Sleep is taken out of the running time")
  func sleepIsNotRunningTime() {
    let subject = run(
      from: date(24, 9), to: date(24, 13),
      suspensions: [DateInterval(start: date(24, 10), end: date(24, 12))])
    #expect(subject.runningTime(in: nil, now: date(25, 0)) == 2 * 3_600)
  }

  @Test("An open run counts until now")
  func openRunRunsUntilNow() {
    let subject = run(from: date(24, 9), to: nil)
    #expect(subject.runningTime(in: nil, now: date(24, 9, 30)) == 30 * 60)
  }

  @Test("A run across midnight is split between the two days")
  func runAcrossMidnightIsSplit() {
    let subject = run(from: date(23, 23), to: date(24, 1))
    let today = UsagePeriod.today.interval(now: date(24, 12), calendar: calendar)
    let report = UsageAggregator.report(
      runs: [subject], tokens: [], period: today, grouping: .session, now: date(24, 12),
      calendar: calendar)
    #expect(report.total.runningTime == 3_600)
    // Started the day before: its time counts today, its start does not.
    #expect(report.total.runs.total == 0)
    let days = UsageAggregator.dailyTimes(
      of: subject, within: nil, now: date(24, 12), calendar: calendar)
    #expect(days.map(\.1) == [3_600, 3_600])
  }

  @Test("A run across the end of a month is cut at the month")
  func previousMonthIsCut() {
    let subject = run(from: date(31, 22, month: 8), to: date(1, 2))
    let previous = UsagePeriod.previousMonth.interval(now: date(24, 12), calendar: calendar)
    let report = UsageAggregator.report(
      runs: [subject], tokens: [], period: previous, grouping: .provider, now: date(24, 12),
      calendar: calendar)
    #expect(report.total.runningTime == 2 * 3_600)
  }

  @Test("By model, time goes to the configured model and tokens to the declared one")
  func modelGrouping() {
    let session = SessionID()
    let subject = run(session, model: nil, from: date(24, 9), to: date(24, 10))
    let bucket = TokenUsageBucket(
      sessionID: session, providerID: "claude-code", model: "claude-opus-5-5",
      day: LocalDay(date(24, 9), calendar: calendar), tokens: TokenCounts(input: 10, output: 5),
      responses: 2)
    let report = UsageAggregator.report(
      runs: [subject], tokens: [bucket], period: nil, grouping: .model, now: date(24, 12),
      calendar: calendar)
    let keys = Set(report.rows.map(\.key))
    #expect(keys.contains(.model(providerID: "claude-code", model: nil)))
    #expect(keys.contains(.model(providerID: "claude-code", model: "claude-opus-5-5")))
    #expect(report.total.tokens.input == 10)
    #expect(report.total.responses == 2)
  }

  @Test("A row without reported tokens says so rather than showing zero")
  func unreportedIsNotZero() {
    let report = UsageAggregator.report(
      runs: [run(provider: "mock", from: date(24, 9), to: date(24, 10))], tokens: [],
      period: nil, grouping: .session, now: date(24, 12), calendar: calendar)
    #expect(report.rows.first?.hasReportedTokens == false)
    #expect(report.total.hasReportedTokens == false)
  }

  @Test("Tokens outside the period are left out")
  func tokensOutsideThePeriod() {
    let bucket = TokenUsageBucket(
      sessionID: SessionID(), providerID: "codex", model: "gpt",
      day: LocalDay(date(1, 9), calendar: calendar),
      tokens: TokenCounts(input: 99), responses: 1)
    let week = UsagePeriod.last7Days.interval(now: date(24, 12), calendar: calendar)
    let report = UsageAggregator.report(
      runs: [], tokens: [bucket], period: week, grouping: .provider, now: date(24, 12),
      calendar: calendar)
    #expect(report.rows.isEmpty)
  }

  @Test("Runs of each kind are counted apart")
  func runKinds() {
    let session = SessionID()
    var counts = UsageRunCounts()
    counts.count(run(session, kind: .start, from: date(24, 9), to: date(24, 10)))
    counts.count(
      UsageRun(
        sessionID: session, providerID: "codex", modelID: nil, kind: .resume, afterRelaunch: true,
        startedAt: date(24, 11)))
    counts.count(
      UsageRun(
        sessionID: session, providerID: "codex", modelID: nil, kind: .restartWithSummary,
        afterSwitch: true, startedAt: date(24, 12)))
    #expect(counts.starts == 1)
    #expect(counts.resumes == 1)
    #expect(counts.restarts == 1)
    #expect(counts.afterRelaunch == 1)
    #expect(counts.afterSwitch == 1)
  }

  @Test("Tracking intervals decide what is counted")
  func trackingIntervals() {
    let intervals = [
      UsageTrackingInterval(from: .distantPast, to: date(20, 0)),
      UsageTrackingInterval(from: date(22, 0)),
    ]
    #expect(intervals.tracks(date(19, 12)))
    #expect(!intervals.tracks(date(21, 12)))
    #expect(intervals.tracks(date(23, 12)))
    #expect(intervals.isTracking)
  }

  @Test("A local day reads and writes as YYYY-MM-DD")
  func localDayRoundTrip() throws {
    let day = LocalDay(year: 2026, month: 9, day: 4)
    #expect(day.description == "2026-09-04")
    let data = try JSONEncoder().encode(day)
    #expect(try JSONDecoder().decode(LocalDay.self, from: data) == day)
  }
}
