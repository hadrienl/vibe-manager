import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

private actor RulesRepository: SessionRepository {
  private var stored: [WorkSession]

  init(sessions: [WorkSession]) {
    stored = sessions
  }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? {
    stored.first { $0.id == id }
  }

  func save(_ session: WorkSession) {
    if let index = stored.firstIndex(where: { $0.id == session.id }) {
      stored[index] = session
    } else {
      stored.append(session)
    }
  }
}

private struct NoAgents: AgentProviderResolving {
  func descriptors() async -> [AgentDescriptor] { [] }
  func provider(id: AgentProviderID) async -> (any AgentProvider)? { nil }
  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] { [:] }
}

@MainActor
private final class ArchiveNotifier: RequestNotifying {
  private(set) var runs: [(String, Int)] = []
  private(set) var batches: [UUID?] = []
  func post(_: RequestNotification) {
    // Only the archive's notification counts here.
  }
  func remove(_: [AgentRequestID]) {
    // Nothing is posted to remove.
  }
  func setBadge(_: Int?) {
    // The badge is not what these tests look at.
  }
  func isAuthorized() async -> Bool? { true }
  func postArchiveRun(ruleName: String, count: Int, batchID: UUID?) {
    runs.append((ruleName, count))
    batches.append(batchID)
  }
}

/// An agent that always writes the same paragraph.
private struct WritingSynthesizers: ArchiveSynthesizerResolving, ArchiveSynthesizing {
  func synthesizer() async -> (providerID: String, synthesizer: any ArchiveSynthesizing)? {
    ("claude", self)
  }

  func synthesize(_ request: ArchiveSynthesisRequest) async throws -> Data {
    Data(#"{"summary":"The reds were shipped."}"#.utf8)
  }
}

/// The rules running in the application (#405): what they archive, how, and what they leave.
@MainActor
@Suite("Archive rules in the application (#405)")
struct ArchiveRulesRunTests {
  let friday = Date(timeIntervalSince1970: 1_792_000_000)

  private func calendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func done(_ name: String, color: String) -> WorkSession {
    let created = friday.addingTimeInterval(-10 * 86_400)
    var session = WorkSession(
      name: name, appearance: SessionAppearance(colorHex: color), status: .closed,
      createdAt: created, updatedAt: created, closedAt: created, startedAt: created,
      statusHistory: .created(in: .todo, at: created))
    try? session.setTaskStatus(.done, at: created.addingTimeInterval(3600), cause: .user)
    return session
  }

  /// A model whose rule is due now: daily at the time `friday` is, turned on the day before.
  private func model(
    state: StoredArchiveRule.State = .active, notifies: Bool = true, summarizes: Bool = true
  ) async -> (
    AppModel, RulesRepository, ArchiveNotifier, [WorkSession], InMemoryArchiveRuleStore
  ) {
    let sessions = [done("Red", color: "#B42318"), done("Blue", color: "#0B63E5")]
    let repository = RulesRepository(sessions: sessions)
    let model = AppModel(repository: repository, agents: NoAgents())
    let notifier = ArchiveNotifier()
    model.requestNotifier = notifier
    let time = calendar().dateComponents([.hour, .minute], from: friday)
    let text = String(
      format:
        "rule \"Reds\" archive done sessions where badge.color = #B42318 on daily at %02d:%02d",
      time.hour ?? 0, time.minute ?? 0)
    let store = InMemoryArchiveRuleStore(
      ArchiveRuleSet(
        rules: [
          StoredArchiveRule(
            text: text, state: state, sentence: "", agent: "claude",
            createdAt: friday.addingTimeInterval(-86_400),
            activatedAt: friday.addingTimeInterval(-86_400), summarizes: summarizes)
        ], notifies: notifies))
    let rules = ArchiveRulesModel(
      store: store, now: { [friday] in friday }, calendar: { [calendar] in calendar() })
    rules.startsTicker = false
    model.archiveRules = rules
    model.archiveReports = ArchiveReportsModel(
      synthesizers: WritingSynthesizers(), now: { [friday] in friday },
      calendar: { [calendar] in calendar() })
    await model.load()
    return (model, repository, notifier, sessions, store)
  }

  @Test("A rule due archives what it names, says the rule in the history, and ⌘Z leaves it")
  func archives() async throws {
    let (model, repository, notifier, sessions, store) = await model()
    await model.runArchiveRules()

    let red = try #require(await repository.session(id: sessions[0].id))
    #expect(red.status == .archived)
    guard case .rule(_, let name)? = red.statusHistory.lastEntryCause else {
      Issue.record("The history does not name the rule")
      return
    }
    #expect(name == "Reds")
    #expect(await repository.session(id: sessions[1].id)?.status == .closed)
    #expect(notifier.runs.map(\.0) == ["Reds"])
    let result = try #require(await store.load().rules.first?.lastRun)
    #expect(result.archived == 1)
    #expect(!result.isTrial)

    // Ran once: the same time does not run again.
    await model.runArchiveRules()
    #expect(notifier.runs.count == 1)

    // Undone from the archive, never by ⌘Z.
    #expect(!model.canUndoSidebarChange)
  }

  @Test("The session on screen archived by a rule hands the selection to its neighbour")
  func handOff() async throws {
    let (model, _, _, sessions, _) = await model()
    model.setColumn(.done)
    model.select(sessions[0].id)
    await model.runArchiveRules()
    #expect(model.selectedSessionID == sessions[1].id)
  }

  @Test("A name another rule has is asked again, never replaced")
  func rename() async throws {
    let (model, _, _, _, store) = await model()
    let rules = try #require(model.archiveRules)
    let sheet = ArchiveRuleSheetModel(purpose: .newRules, rules: rules) { .sample }
    sheet.announce = { _ in }
    let document = try ArchiveRuleParser.parse(
      #"rule "reds" archive done sessions on daily at 18:00"#)
    sheet.setVersionForTesting(document)

    #expect(!(await sheet.save(trial: false)))
    #expect(sheet.renames.map(\.original) == ["reds"])
    sheet.renames[0].name = "Reds"
    #expect(sheet.renameProblem != nil)
    sheet.renames[0].name = "Reds \u{202E}yad"
    #expect(sheet.renameProblem != nil)
    sheet.renames[0].name = "🧑‍💻 Reds"
    #expect(sheet.renameProblem == nil)
    sheet.renames[0].name = "Reds, every day"
    #expect(sheet.renameProblem == nil)
    #expect(await sheet.saveRenamed())
    let names = await store.load().rules.compactMap { $0.rule?.name }
    #expect(names == ["Reds", "Reds, every day"])
  }

  @Test("The names asked for go with their version: a new one asks again")
  func renamesFollowTheVersion() async throws {
    let (model, _, _, _, _) = await model()
    let rules = try #require(model.archiveRules)
    let sheet = ArchiveRuleSheetModel(purpose: .newRules, rules: rules) { .sample }
    sheet.announce = { _ in }
    sheet.setVersionForTesting(
      try ArchiveRuleParser.parse(
        #"rule "Other" archive done sessions on daily at 18:00 rule "reds" archive done sessions on daily at 19:00"#
      ))
    #expect(!(await sheet.save(trial: false)))
    #expect(sheet.renames.map(\.id) == [1])
    sheet.setVersionForTesting(
      try ArchiveRuleParser.parse(#"rule "Other" archive done sessions on daily at 18:00"#))
    #expect(sheet.renames.isEmpty)
  }

  @Test("A protection that no longer reads claims nothing: the times due wait for it")
  func unreadableProtection() async throws {
    let (model, repository, _, sessions, store) = await model()
    try await store.update { set in
      set.protections = [StoredArchiveProtection(text: "protect where nonsense", sentence: "")]
    }
    let rules = try #require(model.archiveRules)
    await rules.load()
    await model.runArchiveRules()
    #expect(await repository.session(id: sessions[0].id)?.status == .closed)
    #expect(await store.load().rules.first?.lastHandled == nil)
  }

  @Test("A rule on trial archives nothing, and says what it would have")
  func trial() async throws {
    let (model, repository, notifier, sessions, store) = await model(state: .trial)
    await model.runArchiveRules()
    #expect(await repository.session(id: sessions[0].id)?.status == .closed)
    #expect(notifier.runs.isEmpty)
    let result = try #require(await store.load().rules.first?.lastRun)
    #expect(result.isTrial)
    #expect(result.archived == 1)
  }

  @Test("A run forms a batch with its sessions as they stood; the notification names it")
  func batch() async throws {
    let (model, _, notifier, sessions, _) = await model()
    await model.runArchiveRules()
    let reports = try #require(model.archiveReports)
    let batch = try #require(reports.batches.first)
    #expect(reports.batches.count == 1)
    #expect(batch.ruleName == "Reds")
    #expect(!batch.isTrial)
    #expect(batch.sessions.map(\.name) == ["Red"])
    #expect(batch.sessions.first?.sessionID == sessions[0].id)
    #expect(notifier.batches == [batch.id])

    model.showArchiveReport(batch.id)
    #expect(reports.selection == .batch(batch.id))
    let report = try #require(reports.report)
    #expect(report.totals.sessions == 1)
  }

  @Test("A run on trial forms a batch apart, and archives nothing")
  func trialBatch() async throws {
    let (model, _, _, _, _) = await model(state: .trial)
    await model.runArchiveRules()
    let reports = try #require(model.archiveReports)
    #expect(reports.batches.count == 1)
    #expect(reports.batches.first?.isTrial == true)
    #expect(reports.days.isEmpty)
    reports.showsTrials = true
    #expect(reports.days.count == 1)
  }

  @Test("Archives by hand go to the day's batch")
  func byHand() async throws {
    let (model, _, _, sessions, _) = await model()
    await model.archive(sessions[0].id, askAgain: false)
    await model.archive(sessions[1].id, askAgain: false)
    let reports = try #require(model.archiveReports)
    #expect(reports.batches.count == 1)
    #expect(reports.batches.first?.kind == .manual)
    #expect(Set(reports.batches.first?.sessions.map(\.name) ?? []) == ["Red", "Blue"])
  }

  @Test("A rule asked to summarize has its batch summarized; one that was not, never")
  func ruleSummarizes() async throws {
    let (model, _, _, _, _) = await model()
    await model.runArchiveRules()
    let reports = try #require(model.archiveReports)
    await waitUntil("the batch summarized") {
      if case .ready(let text, _, _) = reports.batches.first?.synthesis {
        text == "The reds were shipped."
      } else {
        false
      }
    }

    let (silent, _, _, _, _) = await self.model(summarizes: false)
    await silent.runArchiveRules()
    let unsummarized = try #require(silent.archiveReports)
    #expect(unsummarized.batches.count == 1)
    #expect(unsummarized.synthesizing.isEmpty)
    #expect(unsummarized.batches.first?.synthesis == nil)
  }

  @Test("Whether a rule summarizes is asked in its sheet, and kept")
  func sheetSummarizes() async throws {
    let (model, _, _, _, store) = await model()
    let rules = try #require(model.archiveRules)
    let sheet = ArchiveRuleSheetModel(purpose: .newRules, rules: rules) { .sample }
    sheet.announce = { _ in }
    sheet.setVersionForTesting(
      try ArchiveRuleParser.parse(#"rule "Blues" archive done sessions on daily at 18:00"#))
    #expect(sheet.summarizes)
    sheet.summarizes = false
    #expect(await sheet.save(trial: false))
    let saved = try #require(await store.load().rules.first { $0.rule?.name == "Blues" })
    #expect(!saved.summarizes)

    let refined = ArchiveRuleSheetModel(purpose: .refine(saved), rules: rules) { .sample }
    #expect(!refined.summarizes)
  }

  @Test("Several archived together form their own batch, summarized when the user asks")
  func selection() async throws {
    let (model, _, _, sessions, _) = await model()
    let reports = try #require(model.archiveReports)
    let ids = sessions.map(\.id)
    let confirmation = try #require(model.confirmation(for: model.batchPlan(.archive, for: ids)))
    #expect(confirmation.summarizeTitle != nil)
    await model.confirmBatch(confirmation, summarizing: true)
    let batch = try #require(reports.batches.first)
    #expect(reports.batches.count == 1)
    #expect(batch.kind == .selection)
    #expect(Set(batch.sessions.map(\.name)) == ["Red", "Blue"])
    await waitUntil("the selection summarized") {
      if case .ready = reports.batches.first?.synthesis { true } else { false }
    }
  }

  @Test("A selection archived without asking is not summarized")
  func selectionWithoutSummary() async throws {
    let (model, _, _, sessions, _) = await model()
    let reports = try #require(model.archiveReports)
    let confirmation = try #require(
      model.confirmation(for: model.batchPlan(.archive, for: sessions.map(\.id))))
    await model.confirmBatch(confirmation)
    #expect(reports.batches.first?.kind == .selection)
    #expect(reports.synthesizing.isEmpty)
    #expect(reports.batches.first?.synthesis == nil)
  }

  @Test("The notification can be turned off")
  func silent() async {
    let (model, _, notifier, _, _) = await model(notifies: false)
    await model.runArchiveRules()
    #expect(notifier.runs.isEmpty)
  }

  @Test("“Would archive now” counts with Git, as a run does")
  func countsWithGit() async throws {
    let (model, _, _, _, store) = await model()
    let rules = try #require(model.archiveRules)
    try await store.update { set in
      set.rules = [
        StoredArchiveRule(
          text: "rule \"Clean\" archive done sessions where not git.dirty on daily at 18:00",
          state: .active, sentence: "", agent: "claude", createdAt: friday, activatedAt: friday)
      ]
    }
    await rules.load()
    // Not read: a folder whose state is not known matches nothing.
    #expect(rules.lines.first?.wouldArchive == 0)
    rules.readGitFacts = { candidates in
      candidates.map { candidate in
        var candidate = candidate
        candidate.isDirty = candidate.session.name == "Red"
        return candidate
      }
    }
    await rules.refreshGitFacts()
    #expect(rules.lines.first?.wouldArchive == 1)
  }

  @Test("A change within the minute a continuous rule just used runs at its end, not later")
  func continuousChange() async throws {
    let (model, repository, _, sessions, store) = await model()
    let rules = try #require(model.archiveRules)
    try await store.update { [friday] set in
      set.rules = [
        StoredArchiveRule(
          text: "rule \"Reds\" archive done sessions where badge.color = #B42318 on continuously",
          state: .active, sentence: "", agent: "claude",
          createdAt: friday.addingTimeInterval(-86_400),
          activatedAt: friday.addingTimeInterval(-86_400),
          lastHandled: friday.addingTimeInterval(-30))
      ]
    }
    await rules.load()
    model.archiveRulesSawChange()
    let waiting = try #require(rules.continuousRun)
    #expect(await repository.session(id: sessions[0].id)?.status == .closed)
    waiting.cancel()
    rules.continuousRun = nil
  }

  @Test("The Done column's button opens the automatic archive's tab")
  func button() async {
    let (model, _, _, _, _) = await model()
    model.showArchiveRulesSettings()
    #expect(model.settingsPage == .archiveRules)
  }
}
