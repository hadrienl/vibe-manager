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

  /// The exit watch used to be armed before the session was stored active. A process already
  /// over by the time it attached ran its close against a session still marked closed — refused,
  /// and swallowed — and the launch then wrote `active` over it: a session listed as running,
  /// with no process, no watch and nothing left to correct it.
  @Test("A process that ends before the launch finishes never leaves the session running")
  func aLaunchThatDiesImmediatelyStillCloses() async throws {
    let stored = session()
    let repository = MutableRepository(sessions: [stored])
    let launcher = launcher(
      supervisor: SpySupervisor(startsFinished: true),
      repository: repository
    )

    await launcher.launch(session: stored, plan: plan())

    try await waitUntil {
      await repository.session(id: stored.id)?.status == .closed
    }
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

  /// SwiftUI dismisses a confirmation dialog *before* running the button's action, and the
  /// dismissal clears the pending session. Confirming that read it back from the model therefore
  /// found nothing, and Archive silently did nothing at all.
  @Test("Confirming archives the session even though the dialog has already been dismissed")
  func confirmingDoesNotDependOnThePendingSession() async {
    let stored = session()
    let repository = MutableRepository(sessions: [stored])
    let model = AppModel(repository: repository, agents: EmptyRegistry())
    await model.load()

    model.requestArchive(stored.id)
    model.cancelArchive()
    await model.archive(stored.id)

    #expect(await repository.session(id: stored.id)?.status == .archived)
  }

  @Test("A confirmed archive moves the session out of the current scope, and back on request")
  func archiveAndUnarchiveFromTheWorkspace() async {
    let kept = session(name: "Still working")
    let archived = session(name: "Done with this")
    let repository = MutableRepository(sessions: [kept, archived])
    let model = AppModel(repository: repository, agents: EmptyRegistry())
    await model.load()

    model.requestArchive(archived.id)
    await model.archive(archived.id)

    #expect(model.archivedSessionCount == 1)

    // Both are finished, so both are under Closed; only their status tells them apart.
    model.setScope(.closed)
    #expect(model.visibleSessions.count == 2)
    #expect(
      model.visibleSessions.filter { $0.status == .archived }.map(\.name)
        == ["Done with this"])

    await model.restore(archived.id)
    #expect(model.visibleSessions.allSatisfy { $0.status == .closed })
    #expect(await repository.session(id: archived.id)?.status == .closed)
  }

  @Test("Archiving keeps the notes and the Git metadata")
  func archivingKeepsTheRecord() async {
    let stored = session()
    let repository = MutableRepository(sessions: [stored])
    let model = AppModel(repository: repository, agents: EmptyRegistry())
    await model.load()

    model.requestArchive(stored.id)
    await model.archive(stored.id)

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
    await model.archive(stored.id)

    #expect(model.detachWarning?.processIdentifier == 4242)
    #expect(model.detachWarning?.action == .archived)
    #expect(model.detachWarning?.message.contains(stored.name) == true)
    #expect(model.detachWarning?.message.contains("archived") == true)
    model.dismissDetachWarning()
    #expect(model.detachWarning == nil)
  }

  /// The warning belongs to the command that could not confirm the stop. A terminal parked in
  /// that state stays there, so reading it again on the next command claimed a stop that was
  /// never attempted, against a process that may have been gone for hours.
  @Test("An unconfirmable stop is warned about once, not again on the next command")
  func theWarningIsNotRepeatedByALaterCommand() async {
    let stored = session()
    let repository = MutableRepository(sessions: [stored])
    let supervisor = SpySupervisor(outcome: .unreachable(processIdentifier: 4242))
    let launcher = launcher(supervisor: supervisor, repository: repository)
    let model = AppModel(repository: repository, agents: EmptyRegistry(), launcher: launcher)
    await model.load()
    await launcher.launch(session: stored, plan: plan())

    await model.close(stored.id)
    #expect(model.detachWarning?.processIdentifier == 4242)
    model.dismissDetachWarning()

    model.requestArchive(stored.id)
    await model.archive(stored.id)

    #expect(model.detachWarning == nil)
    #expect(await repository.session(id: stored.id)?.status == .archived)
  }

  /// The selection is written to survive a store caught mid-write; the facets are reconciled
  /// against the same read, and dropping them there would erase the user's narrowing for good.
  @Test("A load that comes back empty does not erase the saved facets")
  func anEmptyLoadKeepsTheFacets() async {
    let stored = session(status: .active)
    let model = AppModel(
      repository: EmptyingRepository(sessions: [stored]),
      agents: EmptyRegistry()
    )
    await model.load()
    model.toggleProviderFacet("stub")
    #expect(model.filter.agentProviderIDs == ["stub"])

    await model.reload()

    #expect(model.filter.agentProviderIDs == ["stub"])
  }

  /// The layout's save waits out a delay that every change restarts. With the query inside the
  /// saved value, a burst of typing cancelled the write a scope change was waiting on.
  @Test("Typing a query never reaches the stored layout")
  func searchTextStaysInMemory() async {
    let model = AppModel(
      repository: MutableRepository(sessions: [session()]),
      agents: EmptyRegistry(),
      layout: WorkspaceLayoutController(store: MemoryLayoutStore(), saveDelay: .zero)
    )
    await model.load()
    model.setScope(.closed)
    model.setSearchText("webhook")

    #expect(model.filter.searchText == "webhook")
    #expect(model.filter.scope == .closed)
    #expect(model.layout.filter.searchText.isEmpty)
    #expect(model.layout.filter.scope == .closed)
  }

  @Test("Narrowing the list never unmounts a terminal")
  func filteringLeavesThePanesAlone() async {
    let stored = session(name: "Refactor")
    let other = session(name: "Documentation", status: .active)
    let repository = MutableRepository(sessions: [stored, other])
    let launcher = launcher(supervisor: SpySupervisor(), repository: repository)
    let model = AppModel(repository: repository, agents: EmptyRegistry(), launcher: launcher)
    await model.load()
    await launcher.launch(session: stored, plan: plan())
    await model.reload()
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

  // MARK: - ⌘W

  @Test("Close Session applies to a running session only, and to none while it is closing")
  func closeCommandAvailability() async {
    let running = session(name: "Running", status: .active)
    let repository = MutableRepository(sessions: [running])
    let model = AppModel(repository: repository, agents: EmptyRegistry())
    await model.load()
    model.select(nil)

    // No selection: the menu reads `nil`, and the command is disabled — ⌘W beeps.
    #expect(model.selectedSession == nil)

    model.select(running.id)
    #expect(model.selectedSession.map(model.canClose) == true)

    await model.requestClose(running.id)

    let closed = model.sessions.first { $0.id == running.id }
    #expect(closed?.status == .closed)
    // The last running session is gone from the list, and the selection with it: ⌘W beeps.
    #expect((model.selectedSession.map(model.canClose) ?? false) == false)
  }

  @Test("A session whose agent has stopped closes without asking, and the next one is selected")
  func closingAStoppedAgentDoesNotAsk() async {
    let stored = session(name: "Idle", status: .active)
    let other = session(name: "Next", status: .active)
    let repository = MutableRepository(sessions: [stored, other])
    let model = AppModel(repository: repository, agents: EmptyRegistry())
    await model.load()
    model.select(stored.id)

    await model.requestClose(stored.id)

    #expect(model.pendingClose == nil)
    #expect(model.sessions.first { $0.id == stored.id }?.status == .closed)
    // The user closed it to get on with the next one.
    #expect(model.selectedSessionID == other.id)
    #expect(model.filter.scope == .active)
  }

  @Test("Two ⌘W in a row close the selected session, then the next one")
  func twoCloseCommandsCloseTwoSessions() async {
    let first = session(name: "First", status: .active)
    let second = session(name: "Second", status: .active)
    let repository = MutableRepository(sessions: [first, second])
    let model = AppModel(repository: repository, agents: EmptyRegistry())
    await model.load()
    model.select(first.id)

    for _ in 0..<2 {
      guard let selected = model.selectedSession, model.canClose(selected) else { continue }
      await model.requestClose(selected.id)
    }

    #expect(model.sessions.first { $0.id == first.id }?.status == .closed)
    #expect(model.sessions.first { $0.id == second.id }?.status == .closed)
  }

  @Test("A closed session leaves the list and the selection before its agent has stopped")
  func closingMovesOnBeforeTheStop() async {
    let first = session(name: "First", status: .active)
    let second = session(name: "Second", status: .active)
    let third = session(name: "Third", status: .active)
    let repository = MutableRepository(sessions: [first, second, third])
    let supervisor = SpySupervisor(holdsStop: true)
    let launcher = launcher(supervisor: supervisor, repository: repository)
    let model = AppModel(repository: repository, agents: EmptyRegistry(), launcher: launcher)
    await model.load()
    await launcher.launch(session: second, plan: plan())
    await model.reload()
    let order = model.visibleSessions.map(\.id)
    model.select(second.id)

    let closing = Task { await model.confirmClose(second.id) }
    while await supervisor.stopped.isEmpty {
      await Task.yield()
    }

    #expect(!model.visibleSessions.contains { $0.id == second.id })
    let index = order.firstIndex(of: second.id)!
    #expect(model.selectedSessionID == order[index + 1 < order.count ? index + 1 : index - 1])

    await supervisor.releaseStop()
    await closing.value
    #expect(model.sessions.first { $0.id == second.id }?.status == .closed)
    #expect(!model.visibleSessions.contains { $0.id == second.id })
  }

  @Test("Closing a session that stays listed leaves the selection on it")
  func closingAListedSessionKeepsTheSelection() async throws {
    let stopped = session(name: "Stopped", status: .active)
    let other = session(name: "Other", status: .closed)
    let repository = MutableRepository(sessions: [stopped, other])
    let launcher = launcher(supervisor: SpySupervisor(), repository: repository)
    let model = AppModel(repository: repository, agents: EmptyRegistry(), launcher: launcher)
    await model.load()
    await launcher.launch(session: stopped, plan: plan())
    // Closed on record while its agent still runs: the Closed list shows it, and it can be closed.
    var closed = try #require(await repository.session(id: stopped.id))
    try closed.close(at: Date())
    await repository.save(closed)
    await model.reload()
    model.setScope(.closed)
    model.select(stopped.id)
    #expect(model.canClose(closed))

    await model.confirmClose(stopped.id)

    #expect(model.visibleSessions.contains { $0.id == stopped.id })
    #expect(model.selectedSessionID == stopped.id)
  }

  @Test("Closing a selected session hidden by a search leaves the selection on it")
  func closingAHiddenSessionKeepsTheSelection() async {
    let hidden = session(name: "Refactor", status: .active)
    let shown = session(name: "Documentation", status: .active)
    let repository = MutableRepository(sessions: [hidden, shown])
    let model = AppModel(repository: repository, agents: EmptyRegistry())
    await model.load()
    model.select(hidden.id)
    model.setSearchText("documentation")

    await model.requestClose(hidden.id)

    #expect(model.sessions.first { $0.id == hidden.id }?.status == .closed)
    // It was never taken from under the user: the sidebar follows it to Closed, as it did.
    #expect(model.selectedSessionID == hidden.id)
    #expect(model.filter.scope == .closed)
  }

  @Test("A session picked while an agent is stopping keeps the selection")
  func pickingAnotherSessionDuringACloseKeepsIt() async {
    let first = session(name: "First", status: .active)
    let second = session(name: "Second", status: .active)
    let repository = MutableRepository(sessions: [first, second])
    let supervisor = SpySupervisor(holdsStop: true)
    let launcher = launcher(supervisor: supervisor, repository: repository)
    let model = AppModel(repository: repository, agents: EmptyRegistry(), launcher: launcher)
    await model.load()
    await launcher.launch(session: first, plan: plan())
    await model.reload()
    model.select(first.id)

    let closing = Task { await model.confirmClose(first.id) }
    while await supervisor.stopped.isEmpty {
      await Task.yield()
    }
    model.select(second.id)
    await supervisor.releaseStop()
    await closing.value

    #expect(model.sessions.first { $0.id == first.id }?.status == .closed)
    #expect(model.selectedSessionID == second.id)
  }

  @Test("Closing a running agent asks first, and stops nothing until confirmed")
  func closingARunningAgentAsks() async {
    let stored = session(name: "Working", status: .active)
    let repository = MutableRepository(sessions: [stored])
    let supervisor = SpySupervisor()
    let launcher = launcher(supervisor: supervisor, repository: repository)
    let model = AppModel(repository: repository, agents: EmptyRegistry(), launcher: launcher)
    await model.load()
    await launcher.launch(session: stored, plan: plan())
    await model.reload()

    await model.requestClose(stored.id)

    #expect(model.pendingClose?.id == stored.id)
    #expect(await supervisor.stopped.isEmpty)

    model.cancelClose()
    #expect(model.pendingClose == nil)
    #expect(launcher.isRunning(stored.id))

    await model.requestClose(stored.id)
    await model.confirmClose(stored.id)

    #expect(model.pendingClose == nil)
    #expect(await supervisor.stopped == [stored.id])
    #expect(model.confirmsStoppingRunningAgent)
  }

  @Test("“Don't ask again” is remembered, and the settings can turn the question back on")
  func dontAskAgainIsRemembered() async {
    let first = session(name: "First", status: .active)
    let second = session(name: "Second", status: .active)
    let repository = MutableRepository(sessions: [first, second])
    let supervisor = SpySupervisor()
    let launcher = launcher(supervisor: supervisor, repository: repository)
    let preferences = InMemorySessionClosePreferences()
    let model = AppModel(
      repository: repository, agents: EmptyRegistry(), launcher: launcher,
      closePreferences: preferences)
    await model.load()
    await launcher.launch(session: first, plan: plan())
    await launcher.launch(session: second, plan: plan())
    await model.reload()

    await model.requestClose(first.id)
    await model.confirmClose(first.id, askAgain: false)

    #expect(!preferences.confirmsStoppingRunningAgent)

    // A model built on the same preferences — the next launch — does not ask either.
    let relaunched = AppModel(
      repository: repository, agents: EmptyRegistry(), launcher: launcher,
      closePreferences: preferences)
    await relaunched.load()
    await relaunched.requestClose(second.id)

    #expect(relaunched.pendingClose == nil)
    #expect(await supervisor.stopped == [first.id, second.id])

    relaunched.confirmsStoppingRunningAgent = true
    #expect(preferences.confirmsStoppingRunningAgent)
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
    first.setScope(.closed)
    first.setSort(.name)
    first.setSearchText("webhook")
    await first.layout.flush()

    let second = AppModel(
      repository: repository,
      agents: EmptyRegistry(),
      layout: WorkspaceLayoutController(store: store, saveDelay: .zero)
    )
    await second.load()

    #expect(second.filter.scope == .closed)
    #expect(second.filter.sort == .name)
    #expect(second.filter.searchText.isEmpty)
  }

  @Test("⌘1…⌘9 and the arrows walk the list the user is looking at")
  func navigationFollowsTheFilter() async {
    let running = session(name: "Running", status: .active)
    let finished = session(name: "Finished", status: .closed)
    let repository = MutableRepository(sessions: [running, finished])
    let model = AppModel(repository: repository, agents: EmptyRegistry())
    await model.load()

    model.select(position: 1)
    #expect(model.selectedSessionID == running.id)

    // There is only one row in the active scope, so there is nowhere to step to.
    model.selectNext()
    #expect(model.selectedSessionID == running.id)

    model.setScope(.closed)
    model.select(position: 1)
    #expect(model.selectedSessionID == finished.id)
  }

  /// Search narrows as the query grows. Handing the detail column to another session on every
  /// keystroke would swap the terminal being read out from under the user, and leave it swapped
  /// once the query was cleared.
  @Test("Typing a search never moves the selection")
  func searchLeavesTheSelectionAlone() async {
    let first = session(name: "Refactor", status: .active)
    let second = session(name: "Documentation", status: .active)
    let repository = MutableRepository(sessions: [first, second])
    let model = AppModel(repository: repository, agents: EmptyRegistry())
    await model.load()
    model.select(first.id)

    model.setSearchText("documentation")

    #expect(model.visibleSessions.map(\.name) == ["Documentation"])
    #expect(model.selectedSessionID == first.id)
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

/// A store that answers once and then comes back empty — a file read caught mid-write.
private actor EmptyingRepository: SessionRepository {
  private var stored: [WorkSession]
  private var reads = 0

  init(sessions: [WorkSession]) {
    stored = sessions
  }

  func sessions() -> [WorkSession] {
    reads += 1
    return reads > 1 ? [] : stored
  }

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

private actor SpySupervisor: TerminalSupervisor {
  private(set) var startCount = 0
  private(set) var stopped: [SessionID] = []
  private var sessions: [SessionID: FakeTerminalSession] = [:]
  private let outcome: SessionDetachOutcome
  private let startsFinished: Bool
  /// Holds every stop until `releaseStop()`, the way an agent slow to quit keeps a close waiting.
  private let holdsStop: Bool
  private var heldStop: CheckedContinuation<Void, Never>?
  private var isStopReleased = false

  init(
    outcome: SessionDetachOutcome = .stopped, startsFinished: Bool = false,
    holdsStop: Bool = false
  ) {
    self.outcome = outcome
    self.startsFinished = startsFinished
    self.holdsStop = holdsStop
  }

  func releaseStop() {
    isStopReleased = true
    heldStop?.resume()
    heldStop = nil
  }

  func start(_ spec: TerminalSpec, for id: SessionID) throws -> any TerminalSession {
    startCount += 1
    let session = FakeTerminalSession(
      id: id,
      stopOutcome: outcome,
      initialState: startsFinished ? .exited(code: 0) : .running(processIdentifier: 4242)
    )
    sessions[id] = session
    return session
  }

  func session(for id: SessionID) -> (any TerminalSession)? { sessions[id] }

  func stop(id: SessionID, gracePeriod: Duration) async {
    stopped.append(id)
    if holdsStop, !isStopReleased {
      await withCheckedContinuation { heldStop = $0 }
    }
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

  private var currentState: TerminalProcessState
  private var subscribers: [UUID: AsyncStream<TerminalEvent>.Continuation] = [:]
  private let stopOutcome: SessionDetachOutcome

  init(
    id: SessionID,
    stopOutcome: SessionDetachOutcome = .stopped,
    initialState: TerminalProcessState = .running(processIdentifier: 4242)
  ) {
    self.id = id
    self.stopOutcome = stopOutcome
    currentState = initialState
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
