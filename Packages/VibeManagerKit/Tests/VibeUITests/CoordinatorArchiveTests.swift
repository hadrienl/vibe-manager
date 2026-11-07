import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

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
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    return (model, launcher, repository)
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

  // MARK: - By a rule

  private func calendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  @Test("A rule that archives a coordinator archives its children, but those a protection names")
  func byRule() async throws {
    let friday = Date(timeIntervalSince1970: 1_792_000_000)
    let doing = child("TICKET-185", column: .doing, color: "#B42318")
    let protected = child("TICKET-189", column: .doing)
    let (model, _, repository) = makeWorkspace([coordinator, doing, protected])
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
        protections: [
          StoredArchiveProtection(text: "protect where badge.color = #0B63E5", sentence: "")
        ]))
    let rules = ArchiveRulesModel(
      store: store, now: { friday }, calendar: { [calendar] in calendar() })
    rules.startsTicker = false
    model.archiveRules = rules
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
}
