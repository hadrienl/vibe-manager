import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Restarting a closed session from the workspace")
struct SessionRestartTests {
  // MARK: - Fixtures

  private func folder() -> String {
    let path = NSTemporaryDirectory().appending("vibe-restart-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
      atPath: path,
      withIntermediateDirectories: true
    )
    return path
  }

  private func session(
    status: SessionStatus = .closed,
    closedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000),
    providerID: String = "stub",
    resumeIdentifier: String? = "kept-identifier",
    path: String
  ) -> WorkSession {
    WorkSession(
      name: "Refactor the webhook",
      initialPrompt: "Split the signature check out.",
      agent: SessionAgentConfiguration(
        providerID: providerID,
        resumeIdentifier: resumeIdentifier
      ),
      status: status,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      closedAt: closedAt,
      archivedAt: status == .archived ? Date(timeIntervalSince1970: 1_700_000_000) : nil,
      repositories: [RepositoryContext(path: path)]
    )
  }

  /// A session as `CreateSession` actually stores one: closed, sitting entirely on its creation
  /// date, with no agent ever started in it.
  private func neverStartedSession(path: String) -> WorkSession {
    SessionDraft(
      name: "Refactor the webhook",
      initialPrompt: "Split the signature check out.",
      providerID: "stub",
      workingDirectoryPath: path
    )
    .session(createdAt: Date(timeIntervalSince1970: 1_699_000_000))
  }

  private func plan(path: String) -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: AgentProviderID("stub"),
      executablePath: "/usr/bin/true",
      arguments: [],
      environment: [:],
      workingDirectoryPath: path,
      promptDelivery: .none
    )
  }

  private func makeWorkspace(
    session: WorkSession,
    supervisor: WorkspaceSupervisor = WorkspaceSupervisor(),
    provider: WorkspaceProvider = WorkspaceProvider(),
    clock: SessionClock = SystemSessionClock()
  ) -> (AppModel, SessionLauncher, WorkspaceSupervisor, WorkspaceRepository) {
    let repository = WorkspaceRepository(sessions: [session])
    let registry = WorkspaceRegistry(providers: [provider])
    let launcher = SessionLauncher(
      supervisor: supervisor,
      repository: repository,
      agents: registry,
      viewportTimeout: .zero
    )
    let model = AppModel(
      repository: repository,
      agents: registry,
      launcher: launcher,
      clock: clock
    )
    return (model, launcher, supervisor, repository)
  }

  // MARK: - The launcher

  @Test("A restart reuses the pane and writes a dated separator above the new process")
  func restartReusesThePaneAndAnnouncesItself() async {
    let path = folder()
    let subject = session(path: path)
    let (_, launcher, supervisor, _) = makeWorkspace(session: subject)

    await launcher.launch(session: subject, plan: plan(path: path))
    let pane = launcher.pane(for: subject.id)
    // Taken so the assertion below can only see what the restart itself posted.
    _ = pane?.takePendingNotice()
    await supervisor.finish(id: subject.id, state: .exited(code: 0))
    let closed = await launcher.detach(subject.id)

    let restarted = await launcher.restart(
      SessionRestart(
        session: subject,
        plan: plan(path: path),
        mode: .native(identifier: "kept-identifier"),
        explanation: nil
      )
    )

    // The process had already ended on its own, so there was nothing left to stop.
    #expect(closed == .wasNotRunning)
    #expect(restarted == .started)
    #expect(launcher.pane(for: subject.id) === pane)
    let notice = String(decoding: pane?.takePendingNotice() ?? [], as: UTF8.self)
    #expect(notice.contains("Restart"))
    #expect(notice.contains("resumed conversation"))
  }

  @Test("The separator says which of the three restarts this was")
  func separatorNamesTheMode() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    #expect(SessionLauncher.separator(for: .firstLaunch, at: date).contains("first start"))
    #expect(
      SessionLauncher.separator(for: .native(identifier: "x"), at: date)
        .contains("resumed conversation")
    )
    #expect(
      SessionLauncher.separator(for: .freshWithoutContext, at: date).contains("new process")
    )
  }

  @Test("A session that is still running is left alone rather than started a second time")
  func runningSessionIsNotRestarted() async {
    let path = folder()
    let subject = session(path: path)
    let (_, launcher, supervisor, _) = makeWorkspace(session: subject)

    await launcher.launch(session: subject, plan: plan(path: path))
    let restarted = await launcher.restart(
      SessionRestart(
        session: subject,
        plan: plan(path: path),
        mode: .firstLaunch,
        explanation: nil
      )
    )

    // Not a failure: the agent the user asked for is up, and reporting an error over it put a
    // banner on screen about a session that was running perfectly well.
    #expect(restarted == .alreadyRunning)
    #expect(await supervisor.startCount == 1)
  }

  @Test("A launch that failed leaves no separator behind for the next one to show")
  func failedLaunchDropsItsSeparator() async {
    let path = folder()
    let subject = session(path: path)
    let (_, launcher, _, _) = makeWorkspace(
      session: subject,
      supervisor: WorkspaceSupervisor(failure: .resourceLimitReached(code: 35))
    )

    let restarted = await launcher.restart(
      SessionRestart(
        session: subject,
        plan: plan(path: path),
        mode: .native(identifier: "kept-identifier"),
        explanation: nil
      )
    )

    // No reason of its own: the pane holds the terminal's failure and stays on screen with it.
    #expect(restarted == .failed(reason: nil))
    // Kept, it would be drawn above the next process, dating a restart that never happened.
    #expect(launcher.pane(for: subject.id)?.takePendingNotice().isEmpty == true)
  }

  @Test("A session archived while its restart was being prepared is not started")
  func archivedDuringPreparationIsNotStarted() async {
    let path = folder()
    let subject = session(path: path)
    let repository = WorkspaceRepository(sessions: [subject])
    // Archived after the restart read it, which is the whole of the window this guards.
    await repository.archive(subject.id)
    let supervisor = WorkspaceSupervisor()
    let launcher = SessionLauncher(
      supervisor: supervisor,
      repository: repository,
      agents: WorkspaceRegistry(providers: [WorkspaceProvider()]),
      viewportTimeout: .zero
    )

    let restarted = await launcher.restart(
      SessionRestart(
        session: subject,
        plan: plan(path: path),
        mode: .native(identifier: "kept-identifier"),
        explanation: nil
      )
    )

    #expect(restarted == .failed(reason: SessionLauncher.archivedReason))
    #expect(await supervisor.startCount == 0)
  }

  @Test("A session archived mid-launch keeps no process and no pane")
  func archivedMidLaunchLeavesNothingAttached() async {
    let path = folder()
    let subject = session(path: path)
    // Closed when the launch checks, archived by the time it writes: the one ordering in which a
    // process could survive an archive.
    let repository = RacingRepository(session: subject, archiveAfterReads: 1)
    let supervisor = WorkspaceSupervisor()
    let launcher = SessionLauncher(
      supervisor: supervisor,
      repository: repository,
      agents: WorkspaceRegistry(providers: [WorkspaceProvider()]),
      viewportTimeout: .zero
    )

    let restarted = await launcher.restart(
      SessionRestart(
        session: subject,
        plan: plan(path: path),
        mode: .native(identifier: "kept-identifier"),
        explanation: nil
      )
    )

    #expect(restarted == .failed(reason: SessionLauncher.archivedReason))
    #expect(launcher.pane(for: subject.id) == nil)
    #expect(await supervisor.session(for: subject.id) == nil)
    #expect(await repository.session(id: subject.id)?.status == .archived)
  }

  // MARK: - What the workspace offers

  @Test("Restart is offered to a closed session, and to nothing else")
  func restartIsOfferedToClosedSessionsOnly() {
    let path = folder()
    let closed = session(path: path)
    let (model, _, _, _) = makeWorkspace(session: closed)

    #expect(model.canRestart(closed))
    #expect(!model.canRestart(session(status: .active, closedAt: nil, path: path)))
    #expect(!model.canRestart(session(status: .archived, path: path)))
  }

  @Test("Restart is withheld from a session whose agent cannot run")
  func unusableAgentWithholdsTheCommand() async {
    let path = folder()
    let subject = session(providerID: "gone", path: path)
    let (model, _, _, _) = makeWorkspace(session: subject)
    await model.reload()
    await model.refreshResolutions()

    #expect(!model.canRestart(subject))
  }

  @Test("What Restart will do is announced, not left to be discovered")
  func modeIsAnnouncedBeforeTheCommand() async {
    let path = folder()
    let resumable = session(path: path)
    let (resumableModel, _, _, _) = makeWorkspace(session: resumable)
    await resumableModel.reload()
    await resumableModel.refreshResolutions()

    let fresh = session(resumeIdentifier: nil, path: path)
    let (freshModel, _, _, _) = makeWorkspace(session: fresh)
    await freshModel.reload()
    await freshModel.refreshResolutions()

    #expect(resumableModel.expectedRestartMode(for: resumable).contains("resuming its Stub Agent"))
    #expect(freshModel.expectedRestartMode(for: fresh).contains("new process, with a summary"))
  }

  @Test("A session that never ran is started, not restarted")
  func titleFollowsWhetherItEverRan() {
    let path = folder()
    let (model, _, _, _) = makeWorkspace(session: session(path: path))

    // Built as `CreateSession` stores one: closed, on its creation date, never launched. A
    // fixture with `closedAt: nil` described a *running* session, so the "Start Session" wording
    // was only ever proved against a state the store cannot hold.
    #expect(model.restartTitle(for: neverStartedSession(path: path)) == "Start Session")
    #expect(model.restartTitle(for: session(path: path)) == "Restart Session")
  }

  @Test("A session that never ran is offered its own prompt, not a summary")
  func neverStartedIsOfferedItsPrompt() async {
    let path = folder()
    let subject = neverStartedSession(path: path)
    let (model, _, _, _) = makeWorkspace(session: subject)
    await model.reload()
    await model.refreshResolutions()

    #expect(model.expectedRestartMode(for: subject) == "Start Session")

    await model.restart(subject.id)

    // Started outright: no summary to read, and nothing to confirm.
    #expect(model.pendingRestart == nil)
    #expect(model.restartFailure == nil)
  }

  @Test("Two restarts asked at once start one agent")
  func concurrentRestartsStartOneAgent() async {
    let path = folder()
    let subject = session(path: path)
    let (model, _, supervisor, repository) = makeWorkspace(session: subject)
    await model.reload()

    async let first: Void = model.restart(subject.id)
    async let second: Void = model.restart(subject.id)
    _ = await (first, second)

    #expect(await supervisor.startCount == 1)
    #expect(await repository.session(id: subject.id)?.status == .active)
    #expect(model.restartingSessionIDs.isEmpty)
  }

  @Test("A resumable session is restarted without asking anything")
  func nativeResumeNeedsNoConfirmation() async {
    let path = folder()
    let subject = session(path: path)
    let (model, launcher, supervisor, _) = makeWorkspace(session: subject)
    await model.reload()

    await model.restart(subject.id)

    #expect(model.pendingRestart == nil)
    #expect(await supervisor.startCount == 1)
    #expect(launcher.pane(for: subject.id) != nil)
  }

  @Test("A restart writes the lifecycle and nothing else")
  func restartTouchesNothingButTheLifecycle() async throws {
    let path = folder()
    let subject = session(path: path)
    let (model, _, _, repository) = makeWorkspace(session: subject)
    await model.reload()

    await model.restart(subject.id)

    let stored = try #require(await repository.session(id: subject.id))
    #expect(stored.status == .active)
    // Identity, prompt, agent, folders and notes come back bit for bit: a restart re-chooses
    // nothing, which is what "the same agent, folder and appearance are reused" means.
    #expect(stored.name == subject.name)
    #expect(stored.appearance == subject.appearance)
    #expect(stored.initialPrompt == subject.initialPrompt)
    #expect(stored.agent == subject.agent)
    #expect(stored.repositories == subject.repositories)
    #expect(stored.notes == subject.notes)
    #expect(stored.createdAt == subject.createdAt)
  }

  @Test("Without a conversation to resume, the summary is shown before anything is started")
  func freshRestartAsksFirst() async throws {
    let path = folder()
    let subject = session(resumeIdentifier: nil, path: path)
    let (model, _, supervisor, _) = makeWorkspace(session: subject)
    await model.reload()

    await model.restart(subject.id)

    let pending = try #require(model.pendingRestart)
    #expect(pending.sessionID == subject.id)
    #expect(pending.carriesContext)
    #expect(pending.briefText.contains("Refactor the webhook"))
    #expect(!pending.explanation.isEmpty)
    // Nothing has been started, and nothing has been written.
    #expect(await supervisor.startCount == 0)
  }

  @Test("A session waiting on its summary is not restarted a second time")
  func pendingRestartHoldsTheCommand() async {
    let path = folder()
    let subject = session(resumeIdentifier: nil, path: path)
    let (model, _, supervisor, _) = makeWorkspace(session: subject)
    await model.reload()
    await model.restart(subject.id)
    let asked = model.pendingRestart

    // ⌃⌘R again, while the sheet is open.
    await model.restart(subject.id)

    #expect(model.pendingRestart == asked)
    #expect(model.canRestart(subject) == false)
    #expect(await supervisor.startCount == 0)
  }

  @Test("Confirming sends the summary the user read, and clears the question")
  func confirmingStartsTheFreshProcess() async {
    let path = folder()
    let subject = session(resumeIdentifier: nil, path: path)
    let (model, _, supervisor, repository) = makeWorkspace(session: subject)
    await model.reload()
    await model.restart(subject.id)

    await model.confirmRestart("Carry on with the retry path.")

    #expect(model.pendingRestart == nil)
    #expect(await supervisor.startCount == 1)
    #expect(await supervisor.lastSpec?.arguments.contains("Carry on with the retry path.") == true)
    #expect(await repository.session(id: subject.id)?.status == .active)
  }

  @Test("Cancelling starts nothing and leaves the session closed")
  func cancellingChangesNothing() async {
    let path = folder()
    let subject = session(resumeIdentifier: nil, path: path)
    let (model, _, supervisor, repository) = makeWorkspace(session: subject)
    await model.reload()
    await model.restart(subject.id)

    model.cancelRestart()

    #expect(model.pendingRestart == nil)
    #expect(await supervisor.startCount == 0)
    #expect(await repository.session(id: subject.id)?.status == .closed)
  }

  // MARK: - Failures

  @Test("A refused restart is reported, and leaves the session exactly as it was")
  func refusedRestartLeavesTheSessionAlone() async {
    let path = folder()
    let subject = session(providerID: "gone", path: path)
    let (model, _, supervisor, repository) = makeWorkspace(session: subject)
    await model.reload()

    await model.restart(subject.id)

    #expect(model.restartFailure?.message.contains("gone") == true)
    #expect(await supervisor.startCount == 0)
    let stored = await repository.session(id: subject.id)
    #expect(stored?.status == .closed)
    // The identifier survives the failure: a session must not become unresumable by being
    // restarted unsuccessfully.
    #expect(stored?.agent?.resumeIdentifier == "kept-identifier")
    #expect(model.restartingSessionIDs.isEmpty)
  }

  @Test("A terminal that cannot be opened is reported, and the session stays closed")
  func failedLaunchIsReported() async {
    let path = folder()
    let subject = session(path: path)
    let (model, _, _, repository) = makeWorkspace(
      session: subject,
      supervisor: WorkspaceSupervisor(failure: .resourceLimitReached(code: 35))
    )
    await model.reload()

    await model.restart(subject.id)

    #expect(model.restartFailure != nil)
    #expect(await repository.session(id: subject.id)?.status == .closed)
  }

  @Test("A resumed conversation the agent drops at once is remembered, not announced")
  func ghostResumeIsRememberedNotAnnounced() async {
    let path = folder()
    let subject = session(path: path)
    let supervisor = WorkspaceSupervisor(initialState: .exited(code: 1))
    let (model, _, _, _) = makeWorkspace(session: subject, supervisor: supervisor)
    await model.reload()

    await model.restart(subject.id)
    await waitUntil { model.resumeRefusals.contains(subject.id) }

    // One process, and it is the resumed one: nothing was relaunched on the user's behalf, and
    // nothing was put on screen over a session the user has just finished with.
    #expect(await supervisor.startCount == 1)
    #expect(model.pendingRestart == nil)
    #expect(model.restartFailure == nil)
  }

  @Test("The next restart of that session says so, and does not hand the conversation back")
  func aRefusedResumeIsToldAtTheNextRestart() async {
    let path = folder()
    let subject = session(path: path)
    let supervisor = WorkspaceSupervisor(initialState: .exited(code: 1))
    let (model, _, _, _) = makeWorkspace(session: subject, supervisor: supervisor)
    await model.reload()
    await model.restart(subject.id)
    await waitUntil { model.resumeRefusals.contains(subject.id) }

    await model.restart(subject.id)

    // The news reaches the user where it is useful: in the summary they are about to send, at
    // the moment they ask for the session back.
    let pending = model.pendingRestart
    #expect(pending?.sessionID == subject.id)
    #expect(
      pending?.explanation.contains("stopped as soon as this conversation was resumed") == true
    )
  }

  @Test("A refusal recorded while the launch was still in flight survives its own success")
  func aRefusalIsNotWipedByTheLaunchThatEarnedIt() async {
    let path = folder()
    let subject = session(path: path)
    let supervisor = WorkspaceSupervisor(initialState: .exited(code: 1))
    // An observer that takes its time is what makes the ordering certain rather than lucky: the
    // exit of a refused resume then reaches the model *inside* the call that goes on to report
    // success. On CI, where the machine is loaded, that is the ordinary ordering — and the
    // refusal was being wiped by the very launch that earned it, so the next restart handed the
    // same dead conversation back without a word.
    let (model, _, _, _) = makeWorkspace(
      session: subject,
      supervisor: supervisor,
      provider: WorkspaceProvider(observerDelayYields: 40)
    )
    await model.reload()

    await model.restart(subject.id)
    await waitUntil { model.resumeRefusals.contains(subject.id) }

    #expect(model.resumeRefusals.contains(subject.id))

    // And the next restart says so, instead of resuming a conversation the agent has dropped.
    await model.restart(subject.id)
    #expect(model.pendingRestart?.sessionID == subject.id)
  }

  @Test("An agent worked in for a while and quit is not a refused resume")
  func exitAfterTheProbationIsOrdinary() async {
    let path = folder()
    let subject = session(path: path)
    let clock = SteppableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let supervisor = WorkspaceSupervisor()
    let (model, _, _, _) = makeWorkspace(session: subject, supervisor: supervisor, clock: clock)
    await model.reload()
    await model.restart(subject.id)

    // Twenty seconds of work, then the agent exits with an error of its own.
    clock.advance(by: 20)
    await supervisor.finish(id: subject.id, state: .exited(code: 1))
    await waitUntil { model.sessions.first?.status == .closed }

    #expect(model.resumeRefusals.isEmpty)
  }

  @Test("A clean exit right after a resume is an agent that finished, not a refused resume")
  func cleanExitIsNotAGhostResume() async {
    let path = folder()
    let subject = session(path: path)
    let supervisor = WorkspaceSupervisor(initialState: .exited(code: 0))
    let (model, _, _, _) = makeWorkspace(session: subject, supervisor: supervisor)
    await model.reload()

    await model.restart(subject.id)
    await waitUntil { model.sessions.first?.status == .closed }

    #expect(model.resumeRefusals.isEmpty)
  }

  @Test("A session the user closed himself never counts as a conversation the agent refused")
  func aDeliberateCloseIsNotARefusedResume() async {
    let path = folder()
    let subject = session(path: path)
    let (model, _, _, _) = makeWorkspace(session: subject)
    await model.reload()
    await model.restart(subject.id)
    await waitUntil { model.sessions.first?.status == .active }

    // Close, inside the probation window: the resume had worked, and the user simply stopped.
    await model.close(subject.id)
    await waitUntil { model.sessions.first?.status == .closed }

    #expect(model.resumeRefusals.isEmpty)
  }

  @Test("An agent the user typed into resumed its conversation, whatever it exits with")
  func inputProvesTheResumeWorked() async {
    let path = folder()
    let subject = session(path: path)
    let supervisor = WorkspaceSupervisor()
    let (model, launcher, _, _) = makeWorkspace(session: subject, supervisor: supervisor)
    await model.reload()
    await model.restart(subject.id)

    await launcher.pane(for: subject.id)?.write([UInt8]("hello".utf8))
    await supervisor.finish(id: subject.id, state: .exited(code: 1))
    await waitUntil { model.sessions.first?.status == .closed }

    #expect(model.resumeRefusals.isEmpty)
  }

  @Test("The exit is reported with the state the process actually ended in")
  func closureCarriesTheFinalState() async {
    let path = folder()
    let subject = session(path: path)
    let supervisor = WorkspaceSupervisor()
    let repository = WorkspaceRepository(sessions: [subject])
    let launcher = SessionLauncher(
      supervisor: supervisor,
      repository: repository,
      agents: WorkspaceRegistry(providers: [WorkspaceProvider()]),
      viewportTimeout: .zero
    )
    // Read back from the pane this was a race — the pane runs its own attachment on its own
    // task — and a listener could be told "still running" about a process that had exited.
    var reported: TerminalProcessState?
    launcher.sessionDidClose = { _, state in reported = state }

    await launcher.launch(session: subject, plan: plan(path: path))
    await supervisor.finish(id: subject.id, state: .exited(code: 3))
    await waitUntil { reported != nil }

    #expect(reported == .exited(code: 3))
  }

  // MARK: - Where the session is after it starts

  @Test("A session restarted from Closed is followed into Active, and stays selected")
  func restartMovesTheSidebarToActive() async {
    let path = folder()
    let subject = session(path: path)
    let (model, _, _, _) = makeWorkspace(session: subject)
    await model.reload()
    model.setScope(.closed)
    model.select(subject.id)

    await model.restart(subject.id)

    // The sidebar splits on whether an agent is running, so the session left Closed the moment
    // it started. Left alone, it would have vanished from the list under the user's pointer.
    #expect(model.filter.scope == .active)
    #expect(model.selectedSessionID == subject.id)
    #expect(model.visibleSessions.map(\.id) == [subject.id])
  }

  @Test("A restart that failed leaves the sidebar where the session still is")
  func failedRestartStaysInClosed() async {
    let path = folder()
    let subject = session(path: path)
    let (model, _, _, _) = makeWorkspace(
      session: subject,
      supervisor: WorkspaceSupervisor(failure: .resourceLimitReached(code: 35))
    )
    await model.reload()
    model.setScope(.closed)

    await model.restart(subject.id)

    #expect(model.filter.scope == .closed)
    #expect(model.selectedSessionID == subject.id)
  }

  // MARK: - Banners

  @Test("A restart that reached a process clears the refusal it was started to work around")
  func startingClearsTheRefusal() async {
    let path = folder()
    let subject = session(path: path)
    let supervisor = WorkspaceSupervisor(initialState: .exited(code: 1))
    let (model, _, _, _) = makeWorkspace(session: subject, supervisor: supervisor)
    await model.reload()
    await model.restart(subject.id)
    await waitUntil { model.resumeRefusals.contains(subject.id) }

    await supervisor.nextProcessStarts(in: .running(processIdentifier: 99))
    await model.restart(subject.id)
    await model.confirmRestart(model.pendingRestart?.briefText ?? "")

    // The new process has a conversation of its own. Kept, the refusal would skip the resume of
    // an identifier that has since been replaced.
    #expect(!model.resumeRefusals.contains(subject.id))
  }

  @Test("A store that refuses to reopen leaves no process attached to a closed session")
  func refusedReopenLeavesNothingAttached() async {
    let path = folder()
    let subject = session(path: path)
    let repository = RefusingRepository(sessions: [subject])
    let supervisor = WorkspaceSupervisor()
    let model = AppModel(
      repository: repository,
      agents: WorkspaceRegistry(providers: [WorkspaceProvider()]),
      launcher: SessionLauncher(
        supervisor: supervisor,
        repository: repository,
        agents: WorkspaceRegistry(providers: [WorkspaceProvider()]),
        viewportTimeout: .zero
      )
    )
    await model.reload()

    await model.restart(subject.id)

    #expect(model.restartFailure?.message == SessionLauncher.storeRefusedReason)
    #expect(model.pane(for: subject.id) == nil)
    #expect(await supervisor.session(for: subject.id) == nil)
    #expect(await repository.session(id: subject.id)?.status == .closed)
  }

  @Test("An identifier of whitespace promises no conversation the restart cannot resume")
  func blankIdentifierPromisesNoResume() async {
    let path = folder()
    let subject = session(resumeIdentifier: " \n", path: path)
    let (model, _, _, _) = makeWorkspace(session: subject)
    await model.reload()
    await model.refreshResolutions()

    // `RestartSession` trims before it believes an identifier, and this sentence has to agree
    // with it: promising a resume that will not happen is worse than saying nothing.
    #expect(model.expectedRestartMode(for: subject).contains("new process, with a summary"))
  }

  private func waitUntil(
    _ condition: @MainActor () -> Bool,
    attempts: Int = 200
  ) async {
    for _ in 0..<attempts {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}

// MARK: - Doubles

/// A clock a test moves by hand, for the one rule measured in seconds of real time.
private final class SteppableClock: SessionClock, @unchecked Sendable {
  private let lock = NSLock()
  private var time: Date

  init(_ time: Date) {
    self.time = time
  }

  func now() -> Date {
    lock.withLock { time }
  }

  func advance(by seconds: TimeInterval) {
    lock.withLock { time += seconds }
  }
}

/// A store that archives the session under the launch, after it has been read `archiveAfterReads`
/// times. It reproduces the only ordering in which an archive and a launch can cross.
private actor RacingRepository: SessionRepository {
  private var stored: WorkSession
  private var reads = 0
  private let archiveAfterReads: Int

  init(session: WorkSession, archiveAfterReads: Int) {
    stored = session
    self.archiveAfterReads = archiveAfterReads
  }

  func sessions() -> [WorkSession] { [stored] }

  func session(id: SessionID) -> WorkSession? {
    guard stored.id == id else { return nil }
    defer {
      reads += 1
      if reads == archiveAfterReads {
        try? stored.archive(at: stored.updatedAt)
      }
    }
    return stored
  }

  func save(_ session: WorkSession) {
    guard stored.id == session.id else { return }
    stored = session
  }

  func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) throws -> WorkSession? {
    guard stored.id == id else { return nil }
    var session = stored
    try transform(&session)
    stored = session
    return session
  }
}

/// A store that reads fine and refuses every write, for the failure that is neither an archive
/// nor a session that moved: the write itself did not go through.
private actor RefusingRepository: SessionRepository {
  struct Refusal: Error {}

  private var stored: [WorkSession]

  init(sessions: [WorkSession]) {
    stored = sessions
  }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? {
    stored.first { $0.id == id }
  }

  func save(_ session: WorkSession) throws {
    throw Refusal()
  }

  func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) throws -> WorkSession? {
    throw Refusal()
  }
}
