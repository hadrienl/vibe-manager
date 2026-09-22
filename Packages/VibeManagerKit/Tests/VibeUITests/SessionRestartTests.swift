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
    supervisor: SpySupervisor = SpySupervisor(),
    provider: StubProvider = StubProvider()
  ) -> (AppModel, SessionLauncher, SpySupervisor, MutableRepository) {
    let repository = MutableRepository(sessions: [session])
    let registry = StubRegistry(providers: [provider])
    let launcher = SessionLauncher(
      supervisor: supervisor,
      repository: repository,
      agents: registry,
      viewportTimeout: .zero
    )
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
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
    #expect(restarted)
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

  @Test("A session that is still running is not restarted")
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

    #expect(!restarted)
    #expect(await supervisor.startCount == 1)
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

  @Test("A session that never ran is started, not restarted")
  func titleFollowsWhetherItEverRan() {
    let path = folder()
    let (model, _, _, _) = makeWorkspace(session: session(path: path))

    #expect(model.restartTitle(for: session(closedAt: nil, path: path)) == "Start Session")
    #expect(model.restartTitle(for: session(path: path)) == "Restart Session")
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
      supervisor: SpySupervisor(failure: .resourceLimitReached(code: 35))
    )
    await model.reload()

    await model.restart(subject.id)

    #expect(model.restartFailure != nil)
    #expect(await repository.session(id: subject.id)?.status == .closed)
  }

  @Test("A resumed conversation the agent drops at once is offered a fresh start, not given one")
  func ghostResumeIsOfferedNotTaken() async {
    let path = folder()
    let subject = session(path: path)
    let supervisor = SpySupervisor(initialState: .exited(code: 1))
    let (model, _, _, _) = makeWorkspace(session: subject, supervisor: supervisor)
    await model.reload()

    await model.restart(subject.id)
    await waitUntil { model.resumeFailure != nil }

    #expect(model.resumeFailure?.sessionID == subject.id)
    // One process, and it is the resumed one: nothing was relaunched on the user's behalf.
    #expect(await supervisor.startCount == 1)
  }

  @Test("A clean exit right after a resume is an agent that finished, not a refused resume")
  func cleanExitIsNotAGhostResume() async {
    let path = folder()
    let subject = session(path: path)
    let supervisor = SpySupervisor(initialState: .exited(code: 0))
    let (model, _, _, _) = makeWorkspace(session: subject, supervisor: supervisor)
    await model.reload()

    await model.restart(subject.id)
    await waitUntil { model.sessions.first?.status == .closed }

    #expect(model.resumeFailure == nil)
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

  func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) throws -> WorkSession? {
    guard let index = stored.firstIndex(where: { $0.id == id }) else { return nil }
    var session = stored[index]
    try transform(&session)
    stored[index] = session
    return session
  }
}

private actor SpySupervisor: TerminalSupervisor {
  private(set) var startCount = 0
  private(set) var lastSpec: TerminalSpec?
  private var sessions: [SessionID: FakeTerminalSession] = [:]
  private let failure: TerminalError?
  private let initialState: TerminalProcessState

  init(
    failure: TerminalError? = nil,
    initialState: TerminalProcessState = .running(processIdentifier: 4242)
  ) {
    self.failure = failure
    self.initialState = initialState
  }

  func start(_ spec: TerminalSpec, for id: SessionID) throws -> any TerminalSession {
    if let failure { throw failure }
    startCount += 1
    lastSpec = spec
    let session = FakeTerminalSession(id: id, state: initialState)
    sessions[id] = session
    return session
  }

  func session(for id: SessionID) -> (any TerminalSession)? { sessions[id] }

  func stop(id: SessionID, gracePeriod: Duration) async {
    await sessions[id]?.finish(state: .exited(code: 0))
  }

  func stopAll(gracePeriod: Duration) {}

  func finish(id: SessionID, state: TerminalProcessState) async {
    await sessions[id]?.finish(state: state)
  }
}

private actor FakeTerminalSession: TerminalSession {
  nonisolated let id: SessionID
  private var current: TerminalProcessState
  private var continuations: [AsyncStream<TerminalEvent>.Continuation] = []

  init(id: SessionID, state: TerminalProcessState) {
    self.id = id
    current = state
  }

  func attach() -> TerminalAttachment {
    let state = current
    var continuation: AsyncStream<TerminalEvent>.Continuation?
    let events = AsyncStream<TerminalEvent> { continuation = $0 }
    if let continuation {
      if state.isFinished {
        continuation.finish()
      } else {
        continuations.append(continuation)
      }
    }
    return TerminalAttachment(
      state: state,
      history: TerminalHistorySnapshot(bytes: [], droppedByteCount: 0),
      events: events
    )
  }

  func state() -> TerminalProcessState { current }

  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: [], droppedByteCount: 0)
  }

  func write(_ bytes: [UInt8]) {}

  func resize(to size: TerminalSize) {}

  func stop(gracePeriod: Duration) {
    finish(state: .exited(code: 0))
  }

  func kill() {
    finish(state: .terminated(signal: 9))
  }

  func finish(state: TerminalProcessState) {
    guard !current.isFinished else { return }
    current = state
    for continuation in continuations {
      continuation.yield(.stateChanged(state))
      continuation.finish()
    }
    continuations.removeAll()
  }
}

private struct StubProvider: AgentProvider {
  let descriptor = AgentDescriptor(
    id: AgentProviderID("stub"),
    displayName: "Stub Agent",
    capabilities: AgentCapabilities(
      supportsModelSelection: true,
      supportsInitialPrompt: true,
      supportsResume: true
    )
  )

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentAvailability(
      state: .available,
      installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id,
        providerName: descriptor.displayName,
        state: .available,
        summary: "Stub Agent is ready.",
        probedAt: Date(timeIntervalSince1970: 0),
        remediations: []
      )
    )
  }

  func models() async -> [AgentModel] { [] }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    var arguments: [String] = []
    if case .identifier(let identifier) = request.resume {
      arguments.append(contentsOf: ["--resume", identifier])
    }
    if let prompt = request.initialPrompt {
      arguments.append(prompt)
    }
    return AgentLaunchPlan(
      providerID: descriptor.id,
      executablePath: "/usr/bin/true",
      arguments: arguments,
      environment: [:],
      workingDirectoryPath: request.workingDirectoryPath,
      promptDelivery: request.initialPrompt == nil ? .none : .argument
    )
  }
}

private struct StubRegistry: AgentProviderResolving {
  var providers: [StubProvider]

  func descriptors() async -> [AgentDescriptor] { providers.map(\.descriptor) }

  func provider(id: AgentProviderID) async -> (any AgentProvider)? {
    providers.first { $0.descriptor.id == id }
  }

  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
    var result: [AgentProviderID: AgentAvailability] = [:]
    for provider in providers {
      result[provider.descriptor.id] = await provider.availability(forceRefresh: forceRefresh)
    }
    return result
  }
}
