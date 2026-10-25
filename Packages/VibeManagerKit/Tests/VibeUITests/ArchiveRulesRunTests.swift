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
  func postArchiveRun(ruleName: String, count: Int) { runs.append((ruleName, count)) }
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
  private func model(state: StoredArchiveRule.State = .active, notifies: Bool = true) async -> (
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
            activatedAt: friday.addingTimeInterval(-86_400))
        ], notifies: notifies))
    let rules = ArchiveRulesModel(
      store: store, now: { [friday] in friday }, calendar: { [calendar] in calendar() })
    rules.startsTicker = false
    model.archiveRules = rules
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
    sheet.renames[0].name = "Reds, every day"
    #expect(sheet.renameProblem == nil)
    #expect(await sheet.saveRenamed())
    let names = try await store.load().rules.compactMap { $0.rule?.name }
    #expect(names == ["Reds", "Reds, every day"])
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
