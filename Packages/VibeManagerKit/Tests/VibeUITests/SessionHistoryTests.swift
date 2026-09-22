import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Keeping and archiving the session history")
struct SessionHistoryTests {
  private func plan() -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: AgentProviderID("stub"),
      executablePath: "/usr/bin/true",
      arguments: [],
      environment: [:],
      workingDirectoryPath: "/workspace",
      promptDelivery: .argument
    )
  }

  private func session(
    name: String = "Refactor the webhook",
    status: SessionStatus = .closed,
    notes: String? = "Three retries, then it gives up."
  ) -> WorkSession {
    WorkSession(
      name: name,
      initialPrompt: "Make the retries idempotent",
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: "abc-123"),
      status: status,
      closedAt: status == .closed || status == .archived ? Date(timeIntervalSince1970: 50) : nil,
      archivedAt: status == .archived ? Date(timeIntervalSince1970: 60) : nil,
      repositories: [
        RepositoryContext(
          path: "/workspace",
          git: GitSnapshot(repositoryRootPath: "/workspace", branchName: "main", isDirty: true)
        )
      ],
      notes: notes
    )
  }

  private func launcher(
    supervisor: SpySupervisor,
    repository: MutableRepository
  ) -> SessionLauncher {
    SessionLauncher(
      supervisor: supervisor,
      repository: repository,
      agents: EmptyRegistry(),
      viewportTimeout: .zero
    )
  }

  // MARK: - The runtime

  @Test("Closing stops the process and keeps the pane readable")
  func closingKeepsThePane() async throws {
    let stored = session()
    let repository = MutableRepository(sessions: [stored])
    let supervisor = SpySupervisor()
    let launcher = launcher(supervisor: supervisor, repository: repository)
    await launcher.launch(session: stored, plan: plan())

    let closure = try await CloseSession(repository: repository, runtime: launcher)(id: stored.id)

    #expect(closure.session.status == .closed)
    #expect(closure.detachment == .stopped)
    #expect(await supervisor.stopped == [stored.id])
    // The whole point of closing rather than archiving: the last output is still on screen.
    #expect(launcher.pane(for: stored.id) != nil)
    #expect(!launcher.isRunning(stored.id))
  }

  @Test("Archiving leaves nothing attached: no pane, no terminal, nothing running")
  func archivingDetachesEverything() async throws {
    let stored = session()
    let repository = MutableRepository(sessions: [stored])
    let supervisor = SpySupervisor()
    let launcher = launcher(supervisor: supervisor, repository: repository)
    await launcher.launch(session: stored, plan: plan())

    let archival = try await ArchiveSession(repository: repository, runtime: launcher)(
      id: stored.id)

    #expect(archival.session.status == .archived)
    #expect(launcher.pane(for: stored.id) == nil)
    #expect(!launcher.isRunning(stored.id))
    #expect(await supervisor.session(for: stored.id) == nil)
  }

  @Test("Detaching a session that never started is not a failure")
  func detachingIsIdempotent() async {
    let stored = session()
    let launcher = launcher(
      supervisor: SpySupervisor(),
      repository: MutableRepository(sessions: [stored])
    )

    #expect(await launcher.detach(stored.id) == .wasNotRunning)
    await launcher.dispose(stored.id)
    #expect(await launcher.detach(stored.id) == .wasNotRunning)
  }

  @Test("A process the system would not let go of is reported, not glossed over")
  func unreachableProcessIsSurfaced() async {
    let stored = session()
    let supervisor = SpySupervisor(outcome: .unreachable(processIdentifier: 4242))
    let launcher = launcher(
      supervisor: supervisor,
      repository: MutableRepository(sessions: [stored])
    )
    await launcher.launch(session: stored, plan: plan())

    #expect(await launcher.detach(stored.id) == .unreachable(processIdentifier: 4242))
  }

  @Test("An archived session cannot be launched")
  func archivedSessionsAreNeverLaunched() async {
    let stored = session(status: .archived)
    let supervisor = SpySupervisor()
    let launcher = launcher(
      supervisor: supervisor,
      repository: MutableRepository(sessions: [stored])
    )

    let launched = await launcher.launch(session: stored, plan: plan())

    #expect(!launched)
    #expect(await supervisor.startCount == 0)
    #expect(launcher.pane(for: stored.id) == nil)
  }

  @Test("An agent that exits on its own closes its session")
  func aProcessThatEndsClosesTheSession() async throws {
    let stored = session()
    let repository = MutableRepository(sessions: [stored])
    let supervisor = SpySupervisor()
    let launcher = launcher(supervisor: supervisor, repository: repository)
    await launcher.launch(session: stored, plan: plan())
    #expect(await repository.session(id: stored.id)?.status == .active)

    await supervisor.finish(id: stored.id, with: .exited(code: 0))

    try await waitUntil {
      await repository.session(id: stored.id)?.status == .closed
    }
    // Closed, not archived, and the terminal is still there to be read.
    #expect(launcher.pane(for: stored.id) != nil)
  }

  // MARK: - The workspace

  @Test("Archiving is confirmed before it happens")
  func archivingAsksFirst() async {
    let stored = session()
    let repository = MutableRepository(sessions: [stored])
    let model = AppModel(repository: repository, agents: EmptyRegistry())
    await model.load()

    model.requestArchive(stored.id)
    #expect(model.pendingArchive?.id == stored.id)

    model.cancelArchive()
    #expect(model.pendingArchive == nil)
    #expect(await repository.session(id: stored.id)?.status == .closed)
  }

  @Test("A confirmed archive moves the session out of the current scope, and back on request")
  func archiveAndUnarchiveFromTheWorkspace() async {
    let kept = session(name: "Still working")
    let archived = session(name: "Done with this")
    let repository = MutableRepository(sessions: [kept, archived])
    let model = AppModel(repository: repository, agents: EmptyRegistry())
    await model.load()

    model.requestArchive(archived.id)
    await model.confirmArchive()

    #expect(model.visibleSessions.map(\.name) == ["Still working"])
    #expect(model.archivedSessionCount == 1)
    // The selection never stays on a row that is no longer listed.
    #expect(model.selectedSessionID == kept.id)

    model.setScope(.archived)
    #expect(model.visibleSessions.map(\.name) == ["Done with this"])

    await model.restore(archived.id)
    #expect(model.visibleSessions.isEmpty)
    model.setScope(.current)
    #expect(model.visibleSessions.count == 2)
    #expect(await repository.session(id: archived.id)?.status == .closed)
  }

  @Test("Archiving keeps the notes and the Git metadata")
  func archivingKeepsTheRecord() async {
    let stored = session()
    let repository = MutableRepository(sessions: [stored])
    let model = AppModel(repository: repository, agents: EmptyRegistry())
    await model.load()

    model.requestArchive(stored.id)
    await model.confirmArchive()

    let archived = await repository.session(id: stored.id)
    #expect(archived?.notes == stored.notes)
    #expect(archived?.repositories.first?.git?.branchName == "main")
    #expect(archived?.agent?.resumeIdentifier == "abc-123")
    #expect(archived?.initialPrompt == stored.initialPrompt)
  }

  @Test("An unconfirmable stop is shown to the user")
  func detachWarningReachesTheWorkspace() async {
    let stored = session()
    let repository = MutableRepository(sessions: [stored])
    let supervisor = SpySupervisor(outcome: .unreachable(processIdentifier: 4242))
    let launcher = launcher(supervisor: supervisor, repository: repository)
    let model = AppModel(repository: repository, agents: EmptyRegistry(), launcher: launcher)
    await model.load()
    await launcher.launch(session: stored, plan: plan())

    model.requestArchive(stored.id)
    await model.confirmArchive()

    #expect(model.detachWarning?.processIdentifier == 4242)
    #expect(model.detachWarning?.message.contains(stored.name) == true)
    model.dismissDetachWarning()
    #expect(model.detachWarning == nil)
  }

  @Test("Narrowing the list never unmounts a terminal")
  func filteringLeavesThePanesAlone() async {
    let stored = session(name: "Refactor")
    let other = session(name: "Documentation")
    let repository = MutableRepository(sessions: [stored, other])
    let launcher = launcher(supervisor: SpySupervisor(), repository: repository)
    let model = AppModel(repository: repository, agents: EmptyRegistry(), launcher: launcher)
    await model.load()
    await launcher.launch(session: stored, plan: plan())
    let pane = model.pane(for: stored.id)

    model.setSearchText("documentation")

    #expect(model.visibleSessions.map(\.name) == ["Documentation"])
    #expect(model.pane(for: stored.id) === pane)
    #expect(launcher.isRunning(stored.id))
  }

  @Test("The commands offered follow the session's state")
  func commandAvailability() async {
    let repository = MutableRepository(sessions: [])
    let model = AppModel(repository: repository, agents: EmptyRegistry())

    let active = session(name: "Active", status: .active)
    let closed = session(name: "Closed", status: .closed)
    let archived = session(name: "Archived", status: .archived)

    #expect(model.canClose(active) && model.canArchive(active) && !model.canRestore(active))
    #expect(!model.canClose(closed) && model.canArchive(closed) && !model.canRestore(closed))
    #expect(!model.canClose(archived) && !model.canArchive(archived) && model.canRestore(archived))
  }

  @Test("Scope and sort survive a relaunch; the search text does not")
  func filterSurvivesARelaunch() async {
    let store = MemoryLayoutStore()
    let repository = MutableRepository(sessions: [session()])
    let first = AppModel(
      repository: repository,
      agents: EmptyRegistry(),
      layout: WorkspaceLayoutController(store: store, saveDelay: .zero)
    )
    await first.load()
    first.setScope(.all)
    first.setSort(.name)
    first.setSearchText("webhook")
    await first.layout.flush()

    let second = AppModel(
      repository: repository,
      agents: EmptyRegistry(),
      layout: WorkspaceLayoutController(store: store, saveDelay: .zero)
    )
    await second.load()

    #expect(second.filter.scope == .all)
    #expect(second.filter.sort == .name)
    #expect(second.filter.searchText.isEmpty)
  }

  @Test("⌘1…⌘9 and the arrows walk the list the user is looking at")
  func navigationFollowsTheFilter() async {
    let visible = session(name: "Visible")
    let archived = session(name: "Archived", status: .archived)
    let repository = MutableRepository(sessions: [visible, archived])
    let model = AppModel(repository: repository, agents: EmptyRegistry())
    await model.load()

    model.select(position: 1)
    #expect(model.selectedSessionID == visible.id)

    // There is only one row in the current scope, so there is nowhere to step to.
    model.selectNext()
    #expect(model.selectedSessionID == visible.id)

    model.setScope(.archived)
    model.select(position: 1)
    #expect(model.selectedSessionID == archived.id)
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () async -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await condition())
  }
}

// MARK: - Doubles

private actor MutableRepository: SessionRepository {
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

private actor MemoryLayoutStore: WorkspaceLayoutStore {
  private var layout = WorkspaceLayout()

  func load() -> WorkspaceLayout { layout }

  func save(_ layout: WorkspaceLayout) {
    // Round-tripped through the encoding on purpose: what the store keeps is what the document
    // can carry, which is exactly where the search text is meant to be dropped.
    guard let data = try? JSONEncoder().encode(layout),
      let decoded = try? JSONDecoder().decode(WorkspaceLayout.self, from: data)
    else {
      return
    }
    self.layout = decoded
  }
}

private actor SpySupervisor: TerminalSupervisor {
  private(set) var startCount = 0
  private(set) var stopped: [SessionID] = []
  private var sessions: [SessionID: FakeTerminalSession] = [:]
  private let outcome: SessionDetachOutcome

  init(outcome: SessionDetachOutcome = .stopped) {
    self.outcome = outcome
  }

  func start(_ spec: TerminalSpec, for id: SessionID) throws -> any TerminalSession {
    startCount += 1
    let session = FakeTerminalSession(id: id, stopOutcome: outcome)
    sessions[id] = session
    return session
  }

  func session(for id: SessionID) -> (any TerminalSession)? { sessions[id] }

  func stop(id: SessionID, gracePeriod: Duration) async {
    stopped.append(id)
    await sessions[id]?.stop(gracePeriod: gracePeriod)
    // A terminal the supervisor stopped is a terminal it no longer holds, exactly as the real
    // one releases a finished session.
    if outcome != .unreachable(processIdentifier: 4242) {
      sessions[id] = nil
    }
  }

  func stopAll(gracePeriod: Duration) async {
    for id in sessions.keys {
      await stop(id: id, gracePeriod: gracePeriod)
    }
  }

  /// Ends a process the way a `/quit` would: from the outside, without anybody asking.
  func finish(id: SessionID, with state: TerminalProcessState) async {
    await sessions[id]?.finish(with: state)
  }
}

private actor FakeTerminalSession: TerminalSession {
  nonisolated let id: SessionID

  private var currentState: TerminalProcessState = .running(processIdentifier: 4242)
  private var subscribers: [UUID: AsyncStream<TerminalEvent>.Continuation] = [:]
  private let stopOutcome: SessionDetachOutcome

  init(id: SessionID, stopOutcome: SessionDetachOutcome = .stopped) {
    self.id = id
    self.stopOutcome = stopOutcome
  }

  func attach() -> TerminalAttachment {
    let subscriberID = UUID()
    var continuation: AsyncStream<TerminalEvent>.Continuation?
    let stream = AsyncStream<TerminalEvent> { continuation = $0 }
    if let continuation {
      if currentState.isFinished {
        continuation.finish()
      } else {
        subscribers[subscriberID] = continuation
      }
    }
    return TerminalAttachment(
      state: currentState,
      history: TerminalHistorySnapshot(bytes: [], droppedByteCount: 0),
      events: stream
    )
  }

  func state() -> TerminalProcessState { currentState }

  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: [], droppedByteCount: 0)
  }

  func write(_ bytes: [UInt8]) {}

  func resize(to size: TerminalSize) {}

  func stop(gracePeriod: Duration) {
    switch stopOutcome {
    case .unreachable(let processIdentifier):
      finish(with: .failed(.processOutcomeUnknown(processIdentifier: processIdentifier)))
    case .stopped, .wasNotRunning:
      finish(with: .terminated(signal: SIGTERM))
    }
  }

  func kill() {
    finish(with: .terminated(signal: SIGKILL))
  }

  func finish(with state: TerminalProcessState) {
    guard !currentState.isFinished else { return }
    currentState = state
    for continuation in subscribers.values {
      continuation.yield(.stateChanged(state))
      continuation.finish()
    }
    subscribers.removeAll()
  }
}

private struct EmptyRegistry: AgentProviderResolving {
  func descriptors() async -> [AgentDescriptor] { [] }

  func provider(id: AgentProviderID) async -> (any AgentProvider)? { nil }

  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] { [:] }
}
