import Foundation
import Observation
import VibeApplication
import VibeDomain

/// The test bench (#405): made-up sessions built from the rules, run over months with the code of
/// the real runs, and a cursor to see where each session stands on any day. Everything is
/// computed once per change; moving the cursor computes nothing.
@MainActor
@Observable
public final class ArchiveRuleBenchModel: Identifiable {
  public enum Origin: Equatable {
    case stored(StoredArchiveRule)
    case draft
  }

  public enum Zoom: String, CaseIterable, Identifiable, Sendable {
    case day, week, month
    public var id: String { rawValue }

    /// Points a day takes on the timeline.
    var dayWidth: Double {
      switch self {
      case .day: 64
      case .week: 14
      case .month: 4
      }
    }
  }

  /// Where a session stands at the cursor.
  public enum Standing: Equatable {
    case present
    case skipped
    case archived
  }

  public let id = UUID()
  public let document: ArchiveRuleDocument
  public let origin: Origin
  public let start: Date
  public var months = 3 {
    didSet { recompute() }
  }
  public var zoom = Zoom.week
  public var cursor: Date
  public var sessions: [BenchSession] {
    didSet { recompute() }
  }
  public private(set) var offPeriods: [BenchOffPeriod] = [] {
    didSet { recompute() }
  }
  public private(set) var outcome = BenchOutcome()
  /// The fates of the sessions under the version before, when the rules changed: the sessions
  /// whose fate is not the same are pointed out.
  public private(set) var earlierArchivals: [SessionID: BenchOutcome.Archival]?

  @ObservationIgnored let rules: ArchiveRulesModel
  @ObservationIgnored let palette: [ArchiveRuleContext.Color]

  init(
    document: ArchiveRuleDocument, origin: Origin, rules: ArchiveRulesModel,
    palette: [ArchiveRuleContext.Color], sessions: [BenchSession]? = nil,
    earlier: ArchiveRuleBenchModel? = nil
  ) {
    self.document = document
    self.origin = origin
    self.rules = rules
    self.palette = palette
    let calendar = rules.calendar()
    let now = rules.now()
    start = now
    cursor = now
    self.sessions =
      sessions
      ?? ArchiveBenchCases.make(for: document, start: now, calendar: calendar, palette: palette)
    if let earlier {
      offPeriods = earlier.offPeriods
      months = earlier.months
      earlierArchivals = earlier.outcome.archivals
    }
    recompute()
  }

  public var calendar: Calendar { rules.calendar() }

  public var end: Date {
    calendar.date(byAdding: .month, value: months, to: start) ?? start
  }

  /// The rules of the protections kept and of the version tried.
  private var protections: [ArchiveProtection] {
    rules.set.readableProtections ?? []
  }

  func recompute() {
    outcome = ArchiveRuleBench.run(
      document, protections: protections, sessions: sessions, from: start, through: end,
      calendar: calendar, off: offPeriods)
  }

  /// A new list, built again from the rules.
  public func regenerate() {
    sessions = ArchiveBenchCases.make(
      for: document, start: start, calendar: calendar, palette: palette)
  }

  /// Another session, a copy of `session` to change.
  public func duplicate(_ session: BenchSession) {
    var copy = session
    copy = BenchSession(
      name: session.name + " 2", colorHex: session.colorHex, symbolName: session.symbolName,
      showsProjectIcon: session.showsProjectIcon, project: session.project,
      folder: session.folder, agent: session.agent, model: session.model,
      ticket: session.ticket, branch: session.branch, isDirty: session.isDirty,
      cleanAt: session.cleanAt, coordination: session.coordination,
      createdAt: session.createdAt, runningUntil: session.runningUntil, history: session.history)
    sessions.append(copy)
  }

  public func remove(_ session: BenchSession) {
    sessions.removeAll { $0.id == session.id }
  }

  // MARK: The cursor

  public func step(days: Int) {
    let moved = calendar.date(byAdding: .day, value: days, to: cursor) ?? cursor
    cursor = min(max(moved, start), end)
  }

  /// The previous or next time a rule is due.
  public func jump(forward: Bool) {
    let times = dueTimes.map(\.date).sorted()
    let target = forward ? times.first { $0 > cursor } : times.last { $0 < cursor }
    if let target { cursor = target }
  }

  public func today() {
    cursor = start
  }

  /// Every time a rule is due over the span, with the rule's index.
  public var dueTimes: [(date: Date, rule: Int)] {
    document.rules.enumerated().flatMap { index, rule in
      rule.schedule.occurrences(from: start, through: end, calendar: calendar, activatedAt: start)
        .map { (date: $0, rule: index) }
    }
  }

  /// The days the clocks change, and the months too short for a day asked.
  public var calendarMarks: [Date] {
    var marks: [Date] = []
    var cursor = start
    while let next = calendar.timeZone.nextDaylightSavingTimeTransition(after: cursor), next <= end {
      marks.append(next)
      cursor = next
    }
    return marks
  }

  // MARK: The Mac off

  /// The Mac off for `days` from the cursor.
  public func turnOff(days: Int) {
    let end = calendar.date(byAdding: .day, value: days, to: cursor) ?? cursor
    offPeriods.append(BenchOffPeriod(interval: DateInterval(start: cursor, end: end)))
  }

  public func removeOff(_ period: BenchOffPeriod) {
    offPeriods.removeAll { $0.id == period.id }
  }

  // MARK: Reading it

  public func standing(of session: BenchSession) -> Standing {
    if outcome.isArchived(session.id, at: cursor) { return .archived }
    if outcome.skips[session.id]?.contains(where: { $0.date <= cursor }) == true {
      return .skipped
    }
    return .present
  }

  public var counter: String {
    let date = cursor.formatted(
      .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    let standings = sessions.map(standing(of:))
    let archived = standings.filter { $0 == .archived }.count
    let skipped = standings.filter { $0 == .skipped }.count
    let remaining = standings.count - archived - skipped
    return String(
      localized:
        "At \(date): \(archived) archived · \(skipped) skipped · \(remaining) remaining",
      bundle: .module,
      comment: "The test bench of archive rules: where the made-up sessions stand at the cursor.")
  }

  private func day(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
  }

  private func dayAndTime(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
  }

  /// Why a session ends where it does, in one sentence — never the rule's text.
  public func why(_ session: BenchSession) -> String {
    var sentences: [String] = []
    // The first time each reason kept it: the same reason every time is said once.
    var said: Set<ArchiveVerdict> = []
    for skip in outcome.skips[session.id] ?? [] where said.insert(skip.verdict).inserted {
      let date = day(skip.date)
      switch skip.verdict {
      case .running:
        sentences.append(
          String(
            localized: "Skipped on \(date): something was running in it.", bundle: .module,
            comment: "The test bench of archive rules: why a session was not archived that day."))
      case .unarchived:
        sentences.append(
          String(
            localized: "Skipped on \(date): you had taken it out of the archive.",
            bundle: .module,
            comment: "The test bench of archive rules: why a session was not archived that day."))
      case .overLimit:
        sentences.append(
          String(
            localized: "Skipped on \(date): the rule's limit was reached.", bundle: .module,
            comment: "The test bench of archive rules: why a session was not archived that day."))
      default:
        continue
      }
    }
    if let archival = outcome.archivals[session.id] {
      let date = dayAndTime(archival.date)
      sentences.append(
        String(
          localized: "Archived on \(date) by “\(archival.ruleName)”.", bundle: .module,
          comment: "The test bench of archive rules: when and by which rule a session is archived."))
    } else if outcome.skips[session.id] == nil {
      sentences.append(neverSentence(session))
    }
    if let earlierArchivals {
      let before = earlierArchivals[session.id]
      let now = outcome.archivals[session.id]
      if before?.date != now?.date {
        if let before {
          let date = day(before.date)
          sentences.append(
            String(
              localized: "Changed: the version before archived it on \(date).", bundle: .module,
              comment: "The test bench of archive rules: a session whose fate the new version changed."))
        } else {
          sentences.append(
            String(
              localized: "Changed: the version before never archived it.", bundle: .module,
              comment: "The test bench of archive rules: a session whose fate the new version changed."))
        }
      }
    }
    return sentences.joined(separator: " ")
  }

  /// Whether the version before did something else with it.
  public func changed(_ session: BenchSession) -> Bool {
    guard let earlierArchivals else { return false }
    return earlierArchivals[session.id]?.date != outcome.archivals[session.id]?.date
  }

  private func neverSentence(_ session: BenchSession) -> String {
    let explanation = rules.explanation
    switch ArchiveRuleBench.neverReason(
      of: session, document: ArchiveRuleDocument(rules: document.rules, protections: protections),
      at: end, calendar: calendar)
    {
    case .protected(let protection)?:
      let what = explanation.clause(protection.condition)
      return String(
        localized: "Never archived: protected, as a session where \(what).", bundle: .module,
        comment: "The test bench of archive rules.")
    case .notDone?:
      return String(
        localized: "Never archived: it is not in Done.", bundle: .module,
        comment: "The test bench of archive rules.")
    case .notMatching(let part)?:
      let what = explanation.clause(part)
      return String(
        localized: "Never archived: the rule asks that \(what).", bundle: .module,
        comment: "The test bench of archive rules: the part of the rule the session fails.")
    default:
      return String(
        localized: "Never archived over this time.", bundle: .module,
        comment: "The test bench of archive rules.")
    }
  }

  /// What “Not what I wanted” puts in the field to refine: the case, described.
  public func refinement(for session: BenchSession) -> String {
    let color = rules.explanation.vocabulary.color(session.colorHex)
    let status = String(localized: session.status(at: start).label)
    if let archival = outcome.archivals[session.id] {
      let date = dayAndTime(archival.date)
      return String(
        localized:
          "The session “\(session.name)” (\(color), \(status)) should not be archived on \(date).",
        bundle: .module,
        comment: "The test bench of archive rules: a refinement written for the user to complete.")
    }
    return String(
      localized: "The session “\(session.name)” (\(color), \(status)) should be archived.",
      bundle: .module,
      comment: "The test bench of archive rules: a refinement written for the user to complete.")
  }
}
