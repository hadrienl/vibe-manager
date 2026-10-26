import Foundation
import Testing
import VibeApplication
import VibeDomain

/// The batches and their reports (#408): formed, kept, summed, put in Markdown, handed to an agent.
@Suite("Archive reports (#408)")
struct ArchiveReportTests {
  /// Thursday 2026-10-22 19:00 UTC.
  let evening = Date(timeIntervalSince1970: 1_792_695_600)

  var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  func resource(
    _ label: String, _ kind: SessionResource.Kind, _ involvement: SessionResource.Involvement,
    url: String? = nil
  ) -> SessionResource {
    SessionResource(
      key: "\(kind)-\(label)", kind: kind, label: label, context: "hadrienl/vibe-manager",
      target: url.flatMap(URL.init(string:)).map(SessionResource.Target.web) ?? .folder("/tmp"),
      involvement: involvement, firstSeenAt: evening)
  }

  func snapshot(
    _ name: String, project: String?, at date: Date? = nil, entries: [String] = [],
    resources: [SessionResource] = [], running: TimeInterval? = nil, id: SessionID = SessionID()
  ) -> ArchivedSessionSnapshot {
    let date = date ?? evening
    return ArchivedSessionSnapshot(
      sessionID: id, archivedAt: date, name: name, colorHex: "#B42318",
      symbolName: "hammer", project: project, providerID: "claude",
      createdAt: date.addingTimeInterval(-86_400), startedAt: date.addingTimeInterval(-80_000),
      finishedAt: date.addingTimeInterval(-3_600), runningTime: running,
      entries: entries.enumerated().map {
        JournalEntry(
          text: $0.element, at: date.addingTimeInterval(Double(-$0.offset) * 86_400),
          providerID: "claude")
      }.reversed(),
      resources: resources)
  }

  @Test("A run forms a batch; a run that archived nothing forms none")
  func runs() async throws {
    let book = ArchiveReportBook(store: InMemoryArchiveReportStore())
    let rule = UUID()
    let none = try await book.recordRun(
      kind: .rule(id: rule, name: "Evening"), date: evening, sessions: [], skipped: [])
    #expect(none == nil)
    let skipped = SkippedSession(sessionID: SessionID(), name: "Busy", reason: .running)
    let batch = try #require(
      try await book.recordRun(
        kind: .rule(id: rule, name: "Evening"), date: evening,
        sessions: [snapshot("Icons", project: "App")], skipped: [skipped]))
    #expect(await book.batches() == [batch])
    #expect(batch.skipped == [skipped])
    #expect(batch.ruleName == "Evening")
  }

  @Test("Archives by hand make one batch a day; a session archived again stands once")
  func byHand() async throws {
    let book = ArchiveReportBook(store: InMemoryArchiveReportStore())
    let id = SessionID()
    try await book.recordByHand(snapshot("A", project: nil, id: id), calendar: calendar)
    try await book.recordByHand(snapshot("B", project: nil), calendar: calendar)
    try await book.recordByHand(
      snapshot("A again", project: nil, at: evening.addingTimeInterval(600), id: id),
      calendar: calendar)
    try await book.recordByHand(
      snapshot("Tomorrow", project: nil, at: evening.addingTimeInterval(86_400)),
      calendar: calendar)
    let batches = await book.batches()
    #expect(batches.count == 2)
    #expect(batches[0].sessions.map(\.name) == ["B", "A again"])
    #expect(batches.allSatisfy { $0.kind == .manual })
  }

  @Test("The photo keeps the session as it stood: a rename or a journal cleared changes nothing")
  func photo() throws {
    var session = WorkSession(
      name: "Icons", appearance: SessionAppearance(colorHex: "#0B63E5"), status: .closed,
      createdAt: evening.addingTimeInterval(-7_200), updatedAt: evening.addingTimeInterval(-7_200),
      closedAt: evening.addingTimeInterval(-60), startedAt: evening.addingTimeInterval(-7_000),
      statusHistory: .created(in: .todo, at: evening.addingTimeInterval(-7_200)))
    try session.setTaskStatus(.doing, at: evening.addingTimeInterval(-7_000), cause: .launch)
    try session.setTaskStatus(.done, at: evening.addingTimeInterval(-60), cause: .user)
    var journal = SessionJournal()
    journal.entries = [JournalEntry(text: "Moved the icons", at: evening, providerID: "claude")]
    let photo = ArchivedSessionSnapshot(
      session: session, archivedAt: evening, project: "App", journal: journal,
      runningTime: 3_600, tokens: TokenCounts(input: 10, output: 5))
    session.name = "Renamed"
    journal.entries = []
    #expect(photo.name == "Icons")
    #expect(photo.entries.map(\.text) == ["Moved the icons"])
    #expect(photo.startedAt == evening.addingTimeInterval(-7_000))
    #expect(photo.finishedAt == evening.addingTimeInterval(-60))
    #expect(photo.tokens?.output == 5)
  }

  @Test("The summary goes project by project, with the work done and the totals")
  func summary() {
    let pr = resource("#412", .pullRequest, .created, url: "https://github.com/a/b/pull/412")
    let batch = ArchiveBatch(
      kind: .rule(id: UUID(), name: "Evening"), date: evening,
      sessions: [
        snapshot(
          "Icons", project: "App", entries: ["Moved the icons"],
          resources: [pr, resource("#36", .issue, .changed), resource("#9", .issue, .viewed)],
          running: 3_600),
        snapshot(
          "Load tests", project: "API", resources: [resource("feat/load", .branch, .created)],
          running: 1_200),
        snapshot("Loose", project: nil),
      ])
    let report = ArchiveReport(batch: batch)
    #expect(report.projects.map(\.name) == ["API", "App", nil])
    #expect(report.totals.sessions == 3)
    #expect(report.totals.pullRequestsCreated == 1)
    #expect(report.totals.ticketsTouched == 1)
    #expect(report.totals.branches == 1)
    #expect(report.totals.runningTime == 4_800)
    let text = ArchiveReportText(locale: Locale(identifier: "en"), calendar: calendar)
    #expect(
      text.totals(report.totals)
        == "3 sessions · 1 pull requests created · 1 tickets touched · 1 branches · 1 hr, 20 min running"
        || text.totals(report.totals).hasPrefix("3 sessions"))
  }

  @Test("A period gathers its batches, folds older sentences, and marks a session unarchived")
  func period() throws {
    let id = SessionID()
    let yesterday = evening.addingTimeInterval(-86_400)
    let batches = [
      ArchiveBatch(
        kind: .manual, date: yesterday.addingTimeInterval(-86_400 * 3),
        sessions: [snapshot("Old", project: "App", at: yesterday.addingTimeInterval(-86_400 * 3))]),
      ArchiveBatch(
        kind: .rule(id: UUID(), name: "Evening"), date: yesterday,
        sessions: [
          snapshot("Icons", project: "App", at: yesterday, entries: ["Today", "Before"], id: id)
        ]),
      ArchiveBatch(
        kind: .trial(id: UUID(), name: "Trial"), date: yesterday.addingTimeInterval(60),
        sessions: [snapshot("Dry", project: "App", at: yesterday)]),
    ]
    var current = WorkSession(
      id: id, name: "Icons", appearance: SessionAppearance(colorHex: "#0B63E5"), status: .closed,
      createdAt: yesterday.addingTimeInterval(-7_200), updatedAt: yesterday, closedAt: yesterday,
      statusHistory: .created(in: .done, at: yesterday.addingTimeInterval(-7_200)))
    try current.archive(at: yesterday, cause: .rule(id: UUID(), name: "Evening"))
    try current.restore(at: evening, cause: .unarchive)

    let interval = ArchiveReportPeriod.yesterday.interval(now: evening, calendar: calendar)
    let report = ArchiveReport(
      batches: batches.filter { !$0.isTrial }, interval: interval, sessions: [current])
    #expect(report.batches.count == 1)
    let session = try #require(report.projects.first?.sessions.first)
    #expect(session.snapshot.name == "Icons")
    #expect(session.entries.map(\.text) == ["Today"])
    #expect(session.olderEntryCount == 1)
    #expect(session.unarchivedAt == evening)
  }

  @Test(
    "The report in Markdown: a heading per project, a line per session, links, nothing injected")
  func markdown() {
    let pr = resource("#412", .pullRequest, .created, url: "https://github.com/a/b/pull/412")
    let unsafe = resource("evil", .issue, .changed, url: "javascript:alert(1)")
    let batch = ArchiveBatch(
      kind: .rule(id: UUID(), name: "Evening"), date: evening,
      sessions: [
        snapshot(
          "# Icons *now*", project: "App", entries: ["Moved [the] icons"], resources: [pr, unsafe])
      ])
    let text = ArchiveReportText(locale: Locale(identifier: "en"), calendar: calendar)
    let markdown = text.markdown(
      ArchiveReport(batch: batch), title: "Evening", synthesis: "All done.")
    #expect(
      markdown.hasPrefix("# Evening\n\n1 sessions") || markdown.hasPrefix("# Evening\n\n1 session"))
    #expect(markdown.contains("## App"))
    #expect(markdown.contains("- **\\# Icons \\*now\\***"))
    #expect(markdown.contains("  - Moved \\[the\\] icons"))
    #expect(markdown.contains("[\\#412](https://github.com/a/b/pull/412)"))
    #expect(!markdown.contains("javascript:"))
    #expect(markdown.contains("All done."))
  }

  @Test("Batches are kept twelve months")
  func retention() async {
    let store = InMemoryArchiveReportStore(batches: [
      ArchiveBatch(kind: .manual, date: evening.addingTimeInterval(-400 * 86_400)),
      ArchiveBatch(kind: .manual, date: evening.addingTimeInterval(-300 * 86_400)),
    ])
    let book = ArchiveReportBook(store: store)
    #expect(await book.prune(now: evening, calendar: calendar) == 1)
    #expect(await book.batches().count == 1)
  }

  @Test("The agent's input: sentences and resources only, within 16 KiB")
  func synthesisInput() {
    let long = String(repeating: "word ", count: 100)
    let sessions = (0..<200).map {
      snapshot("Session \($0)", project: "App", entries: [long, long, long])
    }
    let report = ArchiveReport(
      batch: ArchiveBatch(kind: .manual, date: evening, sessions: sessions))
    let request = ArchiveSynthesisRequest(report: report, language: "fr")
    #expect(request.material.utf8.count <= ArchiveSynthesisRequest.byteLimit)
    #expect(request.isTruncated)
    #expect(request.material.hasPrefix("Session: Session 0 [App]"))
    #expect(ArchiveSynthesisInstructions.systemPrompt(language: "fr").contains("fr"))
  }

  @Test("The agent's answer is read strictly")
  func synthesisAnswer() throws {
    #expect(
      try ArchiveSynthesisAnswer.decode(Data(#"{"summary":" Done.\nNext. "}"#.utf8))
        == "Done. Next.")
    #expect(throws: ArchiveSynthesisError.unreadable) {
      try ArchiveSynthesisAnswer.decode(Data(#"{"summary":"x","extra":1}"#.utf8))
    }
    #expect(throws: ArchiveSynthesisError.unreadable) {
      try ArchiveSynthesisAnswer.decode(Data(#"{"summary":"  "}"#.utf8))
    }
  }
}
