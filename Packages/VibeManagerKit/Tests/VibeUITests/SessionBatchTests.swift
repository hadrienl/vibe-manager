import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Several sessions selected, one command")
struct SessionBatchTests {
  /// A folder that exists: a session is only launched in one.
  private let path: String = {
    let path = NSTemporaryDirectory().appending("vibe-batch-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }()

  /// A session that ran and is stopped, with a conversation to resume, in the column given.
  private func session(
    _ name: String, in column: SessionTaskStatus = .doing, status: SessionStatus = .closed,
    updatedAt seconds: TimeInterval = 100, resumable: Bool = true
  ) -> WorkSession {
    let date = Date(timeIntervalSince1970: seconds)
    return WorkSession(
      name: name,
      initialPrompt: "Do \(name)",
      agent: SessionAgentConfiguration(
        providerID: "stub", resumeIdentifier: resumable ? "kept-\(name)" : nil),
      status: status,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: date,
      closedAt: status == .closed ? date : nil,
      startedAt: Date(timeIntervalSince1970: 1),
      repositories: [RepositoryContext(path: path)],
      taskStatus: column
    )
  }

  private func plan(for session: WorkSession) -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: AgentProviderID("stub"),
      executablePath: "/usr/bin/true",
      arguments: [],
      environment: [:],
      workingDirectoryPath: path,
      promptDelivery: .argument
    )
  }

  private func makeWorkspace(
    _ sessions: [WorkSession], failing: Set<SessionID> = []
  ) -> (AppModel, SessionLauncher, BatchRepository) {
    let repository = BatchRepository(sessions: sessions, failing: failing)
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    return (model, launcher, repository)
  }

  /// What a ⌘-click on each row after the first leaves the sidebar with.
  private func selectAll(_ sessions: [WorkSession], in model: AppModel) {
    model.select(sessions[0].id)
    var ids: Set<SessionID> = []
    for session in sessions {
      ids.insert(session.id)
      model.selectFromList(ids)
    }
  }

  // MARK: - Selection

  @Test("⌘-clicks select several sessions; the last one clicked is on screen")
  func selectingSeveral() async {
    let sessions = (1...3).map { session("S\($0)", updatedAt: TimeInterval(400 - $0)) }
    let (model, _, _) = makeWorkspace(sessions)
    await model.load()

    selectAll(sessions, in: model)

    #expect(model.selectedSessionIDs == Set(sessions.map(\.id)))
    #expect(model.selectedSessionID == sessions[2].id)
    #expect(model.hasMultipleSelection)
    #expect(model.commandTargets == sessions.map(\.id))
  }

  @Test("Going to a session, Escape, or a filter that hides rows shrinks the selection")
  func shrinkingTheSelection() async {
    let sessions = (1...3).map { session("S\($0)", updatedAt: TimeInterval(400 - $0)) }
    let (model, _, _) = makeWorkspace(sessions)
    await model.load()

    selectAll(sessions, in: model)
    model.setSearchText("S2")
    #expect(model.selectedSessionIDs == [sessions[1].id, sessions[2].id])

    model.setSearchText("")
    selectAll(sessions, in: model)
    model.collapseSelection()
    #expect(model.selectedSessionIDs == [sessions[2].id])

    selectAll(sessions, in: model)
    model.select(position: 1)
    #expect(model.selectedSessionIDs == [sessions[0].id])
    #expect(!model.hasMultipleSelection)
  }

  // MARK: - Archive

  @Test("Archiving a selection asks once, then archives every session")
  func archivingAsksOnce() async {
    let sessions = (1...4).map { session("S\($0)", updatedAt: TimeInterval(400 - $0)) }
    let extra = session("Stays", updatedAt: 10)
    let (model, _, repository) = makeWorkspace(sessions + [extra])
    await model.load()
    selectAll(sessions, in: model)

    let plan = model.batchPlan(.archive, for: model.commandTargets)
    #expect(model.batchTitle(for: plan) == "Archive 4 Sessions…")
    await model.requestBatch(plan)

    let confirmation = try? #require(model.pendingBatch)
    #expect(confirmation?.plan.eligible.count == 4)
    #expect(await repository.archivedCount == 0)

    if let confirmation { await model.confirmBatch(confirmation) }

    #expect(model.pendingBatch == nil)
    #expect(await repository.archivedCount == 4)
    #expect(model.batchReport == nil)
    // The session on screen left: the row that took its place is shown, alone.
    #expect(model.selectedSessionID == extra.id)
    #expect(!model.hasMultipleSelection)
  }

  @Test("A failure on one session does not stop the others, and the report names it")
  func partialFailure() async {
    let sessions = (1...3).map { session("S\($0)", updatedAt: TimeInterval(400 - $0)) }
    let (model, _, repository) = makeWorkspace(sessions, failing: [sessions[1].id])
    await model.load()
    selectAll(sessions, in: model)

    await model.requestBatch(model.batchPlan(.archive, for: model.commandTargets))
    if let confirmation = model.pendingBatch { await model.confirmBatch(confirmation) }

    #expect(await repository.archivedCount == 2)
    let report = try? #require(model.batchReport)
    #expect(report?.message.contains("1 session was not archived.") == true)
    #expect(report?.lines.map(\.id) == [sessions[1].id])
  }

  // MARK: - Close

  @Test("Closing sessions whose agents have stopped asks nothing, and says what it left out")
  func closingIdleSessions() async {
    let open = (1...2).map {
      session("Open\($0)", status: .active, updatedAt: TimeInterval(400 - $0))
    }
    let closed = session("Closed", updatedAt: 100)
    let (model, _, repository) = makeWorkspace(open + [closed])
    await model.load()
    selectAll(open + [closed], in: model)

    let plan = model.batchPlan(.close, for: model.commandTargets)
    #expect(plan.eligible == open.map(\.id))
    #expect(model.batchTitle(for: plan) == "Close 2 Sessions")
    await model.requestBatch(plan)

    #expect(model.pendingBatch == nil)
    for session in open {
      #expect(await repository.session(id: session.id)?.status == .closed)
    }
    #expect(model.batchReport?.message == "1 is already closed.")
  }

  @Test("Closing sessions whose agents run asks #51's question once")
  func closingRunningAgentsAsksOnce() async {
    let running = (1...2).map {
      session("Running\($0)", status: .active, updatedAt: TimeInterval(400 - $0))
    }
    let idle = session("Idle", status: .active, updatedAt: 100)
    let (model, launcher, repository) = makeWorkspace(running + [idle])
    await model.load()
    for session in running { await launcher.launch(session: session, plan: plan(for: session)) }
    await model.reload()
    selectAll(running + [idle], in: model)

    await model.requestBatch(model.batchPlan(.close, for: model.commandTargets))

    let confirmation = try? #require(model.pendingBatch)
    #expect(confirmation?.isClose == true)
    #expect(confirmation?.message.hasPrefix("2 running agents will be stopped.") == true)

    if let confirmation { await model.confirmBatch(confirmation, askAgain: false) }

    #expect(!model.confirmsStoppingRunningAgent)
    for session in running + [idle] {
      #expect(await repository.session(id: session.id)?.status == .closed)
      #expect(!launcher.isRunning(session.id))
    }
  }

  // MARK: - Restart

  @Test("Restarting a selection asks once; a session whose summary must be read is left out")
  func restartingSeveral() async {
    let resumable = (1...2).map { session("R\($0)", updatedAt: TimeInterval(400 - $0)) }
    let summary = session("Summary", updatedAt: 100, resumable: false)
    let (model, launcher, _) = makeWorkspace(resumable + [summary])
    await model.load()
    await model.refreshResolutions()
    selectAll(resumable + [summary], in: model)

    await model.requestBatch(model.batchPlan(.restart, for: model.commandTargets))
    let confirmation = try? #require(model.pendingBatch)
    #expect(confirmation?.plan.eligible.count == 3)
    if let confirmation { await model.confirmBatch(confirmation) }

    for session in resumable { #expect(launcher.isRunning(session.id)) }
    #expect(!launcher.isRunning(summary.id))
    // No summary sheet opened behind the user's back.
    #expect(model.pendingRestart == nil)
    #expect(model.batchReport?.lines.map(\.id) == [summary.id])
  }

  // MARK: - Status

  @Test("Moving a selection asks once, and says which agents will start")
  func movingSeveral() async {
    let planned = (1...2).map {
      SessionDraft(
        name: "P\($0)", initialPrompt: "Plan \($0).", providerID: "stub",
        workingDirectoryPath: path
      ).session(createdAt: Date(timeIntervalSince1970: TimeInterval(1_699_000_000 - $0)))
    }
    let (model, launcher, repository) = makeWorkspace(planned)
    await model.load()
    await model.refreshResolutions()
    model.setColumn(.todo)
    selectAll(planned, in: model)

    let plan = model.batchPlan(.move(to: .doing), for: model.commandTargets)
    await model.requestBatch(plan)
    let confirmation = try? #require(model.pendingBatch)
    #expect(confirmation?.message.contains("2 sessions that never ran") == true)
    if let confirmation { await model.confirmBatch(confirmation) }

    for session in planned {
      #expect(await repository.session(id: session.id)?.taskStatus == .doing)
      #expect(launcher.isRunning(session.id))
    }
    // The column being sorted stays on screen.
    #expect(model.filter.column == .todo)
  }

  @Test("⌥⌘→ on a selection moves it to the next column")
  func movingToTheNextColumn() async {
    let sessions = (1...3).map { session("S\($0)", updatedAt: TimeInterval(400 - $0)) }
    let (model, _, repository) = makeWorkspace(sessions)
    await model.load()
    selectAll(sessions, in: model)

    let plan = try? #require(model.batchMovePlan(forward: true))
    #expect(plan?.action == .move(to: .waiting))
    if let plan { await model.requestBatch(plan) }
    if let confirmation = model.pendingBatch { await model.confirmBatch(confirmation) }

    for session in sessions {
      #expect(await repository.session(id: session.id)?.taskStatus == .waiting)
    }
  }

  // MARK: - Unarchive

  @Test("Unarchiving several sessions asks nothing")
  func unarchivingSeveral() async {
    var archived: [WorkSession] = []
    for index in 1...2 {
      var stored = session("A\(index)", updatedAt: TimeInterval(300 - index))
      try? stored.archive(at: Date(timeIntervalSince1970: 500))
      archived.append(stored)
    }
    let (model, _, repository) = makeWorkspace(archived)
    await model.load()

    await model.requestBatch(model.batchPlan(.unarchive, for: archived.map(\.id)))

    #expect(model.pendingBatch == nil)
    for session in archived {
      #expect(await repository.session(id: session.id)?.status == .closed)
    }
  }
}

/// A store that refuses to write some sessions, for the partial failures.
private actor BatchRepository: SessionRepository {
  struct Refused: LocalizedError {
    var errorDescription: String? { "The store refused this session." }
  }

  private var stored: [WorkSession]
  private let failing: Set<SessionID>

  init(sessions: [WorkSession], failing: Set<SessionID>) {
    stored = sessions
    self.failing = failing
  }

  var archivedCount: Int { stored.filter { $0.status == .archived }.count }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? {
    stored.first { $0.id == id }
  }

  func save(_ session: WorkSession) throws {
    if failing.contains(session.id) { throw Refused() }
    if let index = stored.firstIndex(where: { $0.id == session.id }) {
      stored[index] = session
    } else {
      stored.append(session)
    }
  }

  func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) throws -> WorkSession? {
    if failing.contains(id) { throw Refused() }
    guard let index = stored.firstIndex(where: { $0.id == id }) else { return nil }
    var session = stored[index]
    try transform(&session)
    stored[index] = session
    return session
  }
}
