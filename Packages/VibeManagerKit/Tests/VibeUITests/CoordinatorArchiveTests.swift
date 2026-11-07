import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// The sessions in memory, each one written handed to `written` before the write returns.
private actor WatchedRepository: SessionRepository {
  private var stored: [WorkSession]
  private let written: @Sendable (WorkSession) async -> Void

  init(_ sessions: [WorkSession], written: @escaping @Sendable (WorkSession) async -> Void) {
    stored = sessions
    self.written = written
  }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? {
    stored.first { $0.id == id }
  }

  func save(_ session: WorkSession) async {
    stored.removeAll { $0.id == session.id }
    stored.append(session)
    await written(session)
  }
}

/// A coordinator archived takes its children with it (#525): by hand, in a selection or by a rule.
/// Left behind, they came back as ordinary sessions, filed under worktrees long removed.
@MainActor
@Suite("A coordinator's children go to the archive with it (#525)")
struct CoordinatorArchiveTests {
  /// A folder that exists: a session is only launched in one.
  private let path: String = {
    let path = NSTemporaryDirectory().appending("vibe-family-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }()
  private let created = Date(timeIntervalSince1970: 1_792_000_000 - 10 * 86_400)

  private let coordinatorID = SessionID()

  private func session(
    _ name: String, column: SessionTaskStatus, color: String = "#0B63E5",
    coordination: SessionCoordination? = nil, id: SessionID = SessionID()
  ) -> WorkSession {
    var session = WorkSession(
      id: id, name: name, initialPrompt: "Do \(name)",
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: "kept-\(name)"),
      appearance: SessionAppearance(colorHex: color), status: .closed, createdAt: created,
      updatedAt: created, closedAt: created, startedAt: created,
      repositories: [RepositoryContext(path: path)], coordination: coordination,
      statusHistory: .created(in: .todo, at: created))
    try? session.setTaskStatus(column, at: created.addingTimeInterval(3600), cause: .user)
    return session
  }

  private var coordinator: WorkSession {
    session(
      "Trucs en vrac", column: .done, color: "#B42318", coordination: .coordinator,
      id: coordinatorID)
  }

  private func child(_ name: String, column: SessionTaskStatus, color: String = "#0B63E5")
    -> WorkSession
  {
    session(name, column: column, color: color, coordination: .child(of: coordinatorID))
  }

  private func makeWorkspace(_ sessions: [WorkSession]) -> (
    AppModel, SessionLauncher, CoordinationRepository
  ) {
    let repository = CoordinationRepository(sessions)
    let (model, launcher) = makeWorkspace(on: repository)
    return (model, launcher, repository)
  }

  private func makeWorkspace(on repository: any SessionRepository) -> (AppModel, SessionLauncher) {
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    return (AppModel(repository: repository, agents: registry, launcher: launcher), launcher)
  }

  private func plan(for session: WorkSession) -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: AgentProviderID("stub"), executablePath: "/usr/bin/true", arguments: [],
      environment: [:], workingDirectoryPath: path, promptDelivery: .argument)
  }

  @Test("Archived by hand, a coordinator takes its children; ⌘Z brings them all back")
  func byHand() async throws {
    let doing = child("TICKET-185", column: .doing)
    let done = child("TICKET-186", column: .done)
    let alone = session("Alone", column: .done)
    let (model, _, repository) = makeWorkspace([coordinator, doing, done, alone])
    await model.load()

    await model.requestArchive(coordinatorID)

    for id in [coordinatorID, doing.id, done.id] {
      #expect(await repository.session(id: id)?.status == .archived)
    }
    #expect(await repository.session(id: alone.id)?.status == .closed)

    await model.undoSidebarChange()

    #expect(await repository.session(id: coordinatorID)?.taskStatus == .done)
    #expect(await repository.session(id: doing.id)?.taskStatus == .doing)
    #expect(await repository.session(id: done.id)?.taskStatus == .done)
  }

  @Test("A child left running when the coordinator alone is stopped goes on, unarchived")
  func runningChildGoesOn() async throws {
    let running = child("TICKET-189", column: .doing)
    let idle = child("TICKET-190", column: .doing)
    let (model, launcher, repository) = makeWorkspace([coordinator, running, idle])
    await model.load()
    await launcher.launch(session: running, plan: plan(for: running))
    await model.reload()

    await model.requestArchive(coordinatorID)
    let stop = try #require(model.pendingCoordinatorStop)
    await model.confirmCoordinatorStop(stop, includingChildren: false)

    #expect(await repository.session(id: coordinatorID)?.status == .archived)
    #expect(await repository.session(id: idle.id)?.status == .archived)
    #expect(await repository.session(id: running.id)?.status == .active)
    #expect(launcher.isRunning(running.id))
  }

  @Test("Stopping them all archives them all")
  func stopAllArchivesAll() async throws {
    let running = child("TICKET-189", column: .doing)
    let (model, launcher, repository) = makeWorkspace([coordinator, running])
    await model.load()
    await launcher.launch(session: running, plan: plan(for: running))
    await model.reload()

    await model.requestArchive(coordinatorID)
    let stop = try #require(model.pendingCoordinatorStop)
    await model.confirmCoordinatorStop(stop, includingChildren: true)

    #expect(await repository.session(id: coordinatorID)?.status == .archived)
    #expect(await repository.session(id: running.id)?.status == .archived)
    #expect(!launcher.isRunning(running.id))
  }

  @Test("A selection with a coordinator archives its children in the same batch")
  func inSelection() async throws {
    let doing = child("TICKET-185", column: .doing)
    let alone = session("Alone", column: .done)
    let (model, _, repository) = makeWorkspace([coordinator, doing, alone])
    await model.load()
    model.setColumn(.done)
    model.select(coordinatorID)
    model.selectFromList([coordinatorID, alone.id])

    await model.requestBatch(model.batchPlan(.archive, for: model.commandTargets))
    if let confirmation = model.pendingBatch {
      await model.confirmBatch(confirmation, askAgain: false)
    }

    for id in [coordinatorID, doing.id, alone.id] {
      #expect(await repository.session(id: id)?.status == .archived)
    }
    await model.undoSidebarChange()
    #expect(await repository.session(id: doing.id)?.taskStatus == .doing)
  }

  /// A coordinator in Done, a child archived on its own the hour after, before the coordinator
  /// went, and one In Progress.
  private func familyWithChildArchivedBefore() -> (early: WorkSession, doing: WorkSession) {
    var early = child("TICKET-184", column: .done)
    try? early.archive(at: created.addingTimeInterval(2 * 3600), cause: .user)
    return (early, child("TICKET-185", column: .doing))
  }

  @Test(
    "Unarchived, a coordinator brings back the children archived with it, not one archived before",
    arguments: ["Unarchive", "Move to a column", "Unarchive a selection"])
  func unarchiveBringsChildrenBack(way: String) async throws {
    let (early, doing) = familyWithChildArchivedBefore()
    let (model, _, repository) = makeWorkspace([coordinator, early, doing])
    await model.load()
    await model.requestArchive(coordinatorID)
    #expect(await repository.session(id: doing.id)?.status == .archived)

    switch way {
    case "Unarchive": await model.restore(coordinatorID)
    case "Move to a column": await model.setTaskStatus(.doing, for: coordinatorID)
    default:
      await model.performBatch(
        model.batchPlan(.unarchive, for: [coordinatorID]), skipsAnnounced: true)
    }

    #expect(await repository.session(id: coordinatorID)?.status == .closed)
    #expect(await repository.session(id: doing.id)?.status == .closed)
    #expect(await repository.session(id: early.id)?.status == .archived)
  }

  @Test("Archived in a selection, then unarchived, a coordinator brings its children back")
  func selectionThenUnarchive() async throws {
    let (early, doing) = familyWithChildArchivedBefore()
    let (model, _, repository) = makeWorkspace([coordinator, early, doing])
    await model.load()

    await model.performBatch(model.batchPlan(.archive, for: [coordinatorID]), skipsAnnounced: true)
    #expect(await repository.session(id: doing.id)?.status == .archived)
    await model.restore(coordinatorID)

    #expect(await repository.session(id: doing.id)?.status == .closed)
    #expect(await repository.session(id: early.id)?.status == .archived)
  }

  @Test("A child started again while those before it are archived stays out of the archive")
  func childStartedMeanwhileStays() async throws {
    let (model, launcher, repository) = workspaceStartingOneChild()
    await model.load()

    await model.requestArchive(coordinatorID)

    try await expectOneArchivedOneStarted(launcher, repository)
  }

  /// Two children of the coordinator, in Done and In Progress: the moment the first of them is
  /// written archived, the other is started again.
  private let pair: [(name: String, column: SessionTaskStatus)] = [
    ("TICKET-185", .done), ("TICKET-186", .doing),
  ]

  private func workspaceStartingOneChild() -> (AppModel, SessionLauncher, WatchedRepository) {
    let children = pair.map { child($0.name, column: $0.column) }
    let moment = ArchiveMoment()
    let repository = WatchedRepository([coordinator] + children) { session in
      guard session.status == .archived, session.id != coordinatorID else { return }
      await moment.reached(session.id)
    }
    let (model, launcher) = makeWorkspace(on: repository)
    let plans = Dictionary(uniqueKeysWithValues: children.map { ($0.id, plan(for: $0)) })
    moment.action = { archived in
      guard let other = children.first(where: { $0.id != archived }), let plan = plans[other.id]
      else { return }
      await launcher.launch(session: other, plan: plan)
    }
    return (model, launcher, repository)
  }

  /// One child archived, the other running, out of the archive.
  private func expectOneArchivedOneStarted(
    _ launcher: SessionLauncher, _ repository: WatchedRepository
  ) async throws {
    let children = await repository.sessions().filter { $0.coordination != .coordinator }
    let started = try #require(children.first { launcher.isRunning($0.id) })
    #expect(started.status == .active)
    #expect(children.filter { $0.status == .archived }.count == 1)
  }

  // MARK: - By a rule

  private func calendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private let friday = Date(timeIntervalSince1970: 1_792_000_000)

  /// "Reds", due now, archives the red sessions in Done; `protections` keep what they name.
  private func rules(protecting protections: [String], on model: AppModel)
    -> InMemoryArchiveRuleStore
  {
    let time = calendar().dateComponents([.hour, .minute], from: friday)
    let text = String(
      format:
        "rule \"Reds\" archive done sessions where badge.color = #B42318 on daily at %02d:%02d",
      time.hour ?? 0, time.minute ?? 0)
    let store = InMemoryArchiveRuleStore(
      ArchiveRuleSet(
        rules: [
          StoredArchiveRule(
            text: text, state: .active, sentence: "", agent: "claude",
            createdAt: friday.addingTimeInterval(-86_400),
            activatedAt: friday.addingTimeInterval(-86_400))
        ],
        protections: protections.map { StoredArchiveProtection(text: $0, sentence: "") }))
    let rules = ArchiveRulesModel(
      store: store, now: { [friday] in friday }, calendar: { [calendar] in calendar() })
    rules.startsTicker = false
    model.archiveRules = rules
    return store
  }

  @Test("A rule that archives a coordinator archives its children, but those a protection names")
  func byRule() async throws {
    let doing = child("TICKET-185", column: .doing, color: "#B42318")
    let protected = child("TICKET-189", column: .doing)
    let (model, _, repository) = makeWorkspace([coordinator, doing, protected])
    let store = rules(protecting: ["protect where badge.color = #0B63E5"], on: model)
    await model.load()

    await model.runArchiveRules()

    #expect(await repository.session(id: coordinatorID)?.status == .archived)
    #expect(await repository.session(id: doing.id)?.status == .archived)
    guard
      case .rule(_, let name)? = await repository.session(id: doing.id)?.statusHistory
        .lastEntryCause
    else {
      Issue.record("The child's history does not name the rule")
      return
    }
    #expect(name == "Reds")
    #expect(await repository.session(id: protected.id)?.status == .closed)
    #expect(await store.load().rules.first?.lastRun?.archived == 2)
  }

  @Test("A protection that reads Git reads the children's folders, whatever their column")
  func childrenReadFromGit() async throws {
    let clean = child("TICKET-185", column: .doing)
    let dirty = child("TICKET-186", column: .waiting)
    let (model, _, repository) = makeWorkspace([coordinator, clean, dirty])
    _ = rules(protecting: ["protect where git.dirty"], on: model)
    await model.load()
    model.archiveRules?.readGitFacts = { candidates in
      candidates.map { candidate in
        var candidate = candidate
        candidate.isDirty = candidate.id == dirty.id
        return candidate
      }
    }

    await model.runArchiveRules()

    #expect(await repository.session(id: coordinatorID)?.status == .archived)
    #expect(await repository.session(id: clean.id)?.status == .archived)
    #expect(await repository.session(id: dirty.id)?.status == .closed)
  }

  @Test("A child a rule would take, started again meanwhile, stays out of the archive")
  func ruleLeavesChildStartedMeanwhile() async throws {
    let (model, launcher, repository) = workspaceStartingOneChild()
    _ = rules(protecting: [], on: model)
    await model.load()

    await model.runArchiveRules()

    #expect(await repository.session(id: coordinatorID)?.status == .archived)
    try await expectOneArchivedOneStarted(launcher, repository)
  }

  @Test("A rule naming a worktree's folder still finds its session, filed under its repository")
  func worktreeProject() async throws {
    var hotfix = session("Hotfix", column: .done, color: "#B42318")
    hotfix.repositories = [
      RepositoryContext(path: "/w/mairie-hotfix", mainRepositoryPath: "/w/mairie")
    ]
    let (model, _, repository) = makeWorkspace([hotfix])
    _ = rules(protecting: [#"protect where project = "mairie-hotfix""#], on: model)
    await model.load()
    #expect(model.groupName(of: hotfix) == "mairie")

    await model.runArchiveRules()

    #expect(await repository.session(id: hotfix.id)?.status == .closed)
  }
}

/// What a test does the moment a session is archived, given once the workspace exists.
@MainActor
private final class ArchiveMoment {
  var action: (@MainActor (SessionID) async -> Void)?

  /// Once only: the first session archived.
  func reached(_ id: SessionID) async {
    guard let action else { return }
    self.action = nil
    await action(id)
  }
}
