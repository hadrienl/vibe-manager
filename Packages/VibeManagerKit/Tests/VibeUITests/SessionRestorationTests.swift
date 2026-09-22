import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Restoring sessions when the workspace opens")
struct SessionRestorationTests {
  // MARK: - Fixtures

  private static let launch = Date(timeIntervalSince1970: 1_700_000_000)
  private static let lastSeen = Date(timeIntervalSince1970: 1_700_000_600)

  private func folder() -> String {
    let path = NSTemporaryDirectory().appending("vibe-restore-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  private func session(
    name: String = "Refactor the webhook",
    status: SessionStatus = .closed,
    resumeIdentifier: String? = "kept-identifier",
    path: String
  ) -> WorkSession {
    WorkSession(
      name: name,
      initialPrompt: "Split the signature check out.",
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: resumeIdentifier),
      status: status,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
      closedAt: status == .active ? nil : Date(timeIntervalSince1970: 1_700_000_100),
      repositories: [RepositoryContext(path: path)]
    )
  }

  private func document(
    phase: SessionRuntimeState.Phase,
    processIdentifier: Int32 = 1_001,
    sessions: [SessionRuntimeRecord]
  ) -> SessionRuntimeState {
    SessionRuntimeState(
      phase: phase,
      processIdentifier: processIdentifier,
      launchedAt: Self.launch,
      updatedAt: Self.lastSeen,
      stoppedAt: phase == .stopped ? Self.lastSeen : nil,
      sessions: sessions
    )
  }

  private struct Workspace {
    let model: AppModel
    let launcher: SessionLauncher
    let repository: MutableRepository
    let runtime: EphemeralSessionRuntimeStateStore
    let recorder: SessionRuntimeRecorder
  }

  private func makeWorkspace(
    sessions: [WorkSession],
    document: SessionRuntimeState? = nil,
    alive: Set<Int32> = [],
    runtime: EphemeralSessionRuntimeStateStore? = nil,
    repository: MutableRepository? = nil,
    processIdentifier: Int32 = 4_242
  ) -> Workspace {
    let repository = repository ?? MutableRepository(sessions: sessions)
    let store = runtime ?? EphemeralSessionRuntimeStateStore(state: document)
    let processes = StubProcesses(alive: alive)
    let recorder = SessionRuntimeRecorder(
      store: store,
      processIdentifier: processIdentifier,
      probe: processes
    )
    let registry = StubRegistry(providers: [StubProvider()])
    let launcher = SessionLauncher(
      supervisor: SpySupervisor(),
      repository: repository,
      agents: registry,
      recorder: recorder,
      viewportTimeout: .zero
    )
    let model = AppModel(
      repository: repository,
      agents: registry,
      launcher: launcher,
      runtimeRecorder: recorder,
      processes: processes
    )
    return Workspace(
      model: model,
      launcher: launcher,
      repository: repository,
      runtime: store,
      recorder: recorder
    )
  }

  // MARK: - A clean quit

  @Test("A clean quit brings the sessions back on their own, and says nothing about it")
  func aCleanQuitIsRestored() async {
    let path = folder()
    let subject = session(status: .closed, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(phase: .stopped, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )

    await workspace.model.load()

    #expect(workspace.launcher.isRunning(subject.id))
    #expect(await workspace.repository.status(of: subject.id) == .active)
    #expect(workspace.model.restoration == nil)
    #expect(workspace.model.restoreOffer == nil)
    // Nothing needed the user, so nothing is put in front of them.
    #expect(workspace.model.restoreReport == nil)
  }

  @Test("What came back is written down again, so the next launch knows about it")
  func recordsWhatItRestored() async {
    let path = folder()
    let subject = session(status: .closed, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(phase: .stopped, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )

    await workspace.model.load()

    let state = await workspace.runtime.read()
    #expect(state?.phase == .running)
    #expect(state?.sessions.map(\.sessionID) == [subject.id])
    #expect(state?.sessions.first?.processGroup == 4_242)
  }

  @Test("A session whose conversation is gone stays closed, with its reason in the report")
  func aSessionThatWouldNeedASummaryIsLeftToTheUser() async {
    let path = folder()
    let subject = session(status: .closed, resumeIdentifier: nil, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(phase: .stopped, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )

    await workspace.model.load()

    #expect(!workspace.launcher.isRunning(subject.id))
    #expect(await workspace.repository.status(of: subject.id) == .closed)
    #expect(workspace.model.restoreReport?.lines.count == 1)
    #expect(workspace.model.restoreReport?.lines.first?.name == "Refactor the webhook")
    #expect(workspace.model.restoreReport?.restartedCount == 0)
    // And the command that finishes the job by hand is offered, summary and all.
    let listed = workspace.model.sessions.first { $0.id == subject.id }
    #expect(listed.map(workspace.model.canRestart) == true)
  }

  // MARK: - An unexpected stop

  @Test("An unexpected stop is offered, never taken: nothing is launched by itself")
  func anUnexpectedStopIsOffered() async {
    let path = folder()
    let subject = session(status: .active, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(phase: .running, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )

    await workspace.model.load()

    #expect(workspace.model.restoreOffer?.sessionCount == 1)
    #expect(!workspace.launcher.isRunning(subject.id))
    // The store is honest again before the first list is drawn: nothing is running, so nothing
    // is stored active.
    #expect(await workspace.repository.status(of: subject.id) == .closed)
    #expect(workspace.model.sessions.first?.status == .closed)
  }

  @Test("Accepting the offer restores the sessions, once")
  func acceptingTheOfferRestores() async {
    let path = folder()
    let subject = session(status: .active, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(phase: .running, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )
    await workspace.model.load()

    await workspace.model.acceptRestoreOffer()

    #expect(workspace.launcher.isRunning(subject.id))
    #expect(workspace.model.restoreOffer == nil)
    #expect(await workspace.repository.status(of: subject.id) == .active)

    // Asked again, it has nothing left to do: the offer is gone with the intention it carried.
    await workspace.model.acceptRestoreOffer()
    #expect(await workspace.repository.status(of: subject.id) == .active)
  }

  @Test("Declining the offer leaves the sessions closed and whole")
  func decliningTheOfferKeepsEverything() async {
    let path = folder()
    let subject = session(status: .active, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(phase: .running, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )
    await workspace.model.load()

    workspace.model.dismissRestoreOffer()

    #expect(workspace.model.restoreOffer == nil)
    #expect(!workspace.launcher.isRunning(subject.id))
    let stored = await workspace.repository.session(id: subject.id)
    #expect(stored?.status == .closed)
    #expect(stored?.agent?.resumeIdentifier == "kept-identifier")
  }

  @Test("A leftover process nobody can identify is reported, not signalled")
  func reportsAnUnidentifiableLeftover() async {
    let path = folder()
    let subject = session(status: .active, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(
        phase: .running,
        sessions: [SessionRuntimeRecord(sessionID: subject.id, processGroup: 7_003)]
      ),
      alive: [7_003]
    )

    await workspace.model.load()

    #expect(workspace.model.restoreOffer?.leftoverProcessIdentifiers == [7_003])
    #expect(workspace.model.restoreOffer?.suggestion?.contains("7003") == true)
  }

  // MARK: - The report

  @Test("A cancelled restoration says how many sessions it left closed")
  func reportsWhatACancellationLeftClosed() async {
    let path = folder()
    let first = session(name: "First", path: path)
    let second = session(name: "Second", path: path)
    let workspace = makeWorkspace(sessions: [first, second])

    await workspace.model.finishRestore(with: [
      SessionRestoreOutcome(
        sessionID: first.id, sessionName: "First", result: .restarted(.native(identifier: "k"))),
      SessionRestoreOutcome(
        sessionID: second.id, sessionName: "Second", result: .skipped(.cancelled)),
    ])

    let report = workspace.model.restoreReport
    #expect(report?.cancelledCount == 1)
    #expect(report?.lines.isEmpty == true)
    #expect(report?.message == "1 more was left closed when you cancelled. 1 session came back.")
  }

  @Test("A restoration where everything came back says nothing")
  func staysSilentWhenEverythingCameBack() async {
    let path = folder()
    let subject = session(status: .closed, path: path)
    let workspace = makeWorkspace(sessions: [subject])

    await workspace.model.finishRestore(with: [
      SessionRestoreOutcome(
        sessionID: subject.id,
        sessionName: subject.name,
        result: .restarted(.native(identifier: "kept-identifier"))
      )
    ])

    #expect(workspace.model.restoreReport == nil)
  }

  // MARK: - A second copy

  @Test("A second copy of the application is named, and nothing here is touched")
  func aSecondCopyIsDetected() async {
    let path = folder()
    let subject = session(status: .active, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(
        phase: .running,
        processIdentifier: 1_001,
        sessions: [SessionRuntimeRecord(sessionID: subject.id)]
      ),
      alive: [1_001]
    )

    await workspace.model.load()

    #expect(workspace.model.otherInstanceProcessIdentifier == 1_001)
    #expect(workspace.model.restoreOffer == nil)
    #expect(!workspace.launcher.isRunning(subject.id))
    // Those sessions belong to the other copy: closing them here would stop its agents' work
    // from ever being written down as finished.
    #expect(await workspace.repository.status(of: subject.id) == .active)
  }

  // MARK: - The full circle

  @Test("Quitting and reopening puts the same session back, with everything it carried")
  func theFullCircle() async {
    let path = folder()
    let subject = session(status: .closed, path: path)
    let repository = MutableRepository(sessions: [subject])
    let runtime = EphemeralSessionRuntimeStateStore(
      state: document(phase: .stopped, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )
    let first = makeWorkspace(
      sessions: [subject], runtime: runtime, repository: repository, processIdentifier: 4_242)
    await first.model.load()
    #expect(first.launcher.isRunning(subject.id))

    // Quitting: the same sequence the application delegate runs.
    let prepare = PrepareForQuit(
      repository: repository,
      runtime: first.launcher,
      recorder: first.recorder
    )
    let shutdown = await prepare()

    #expect(shutdown.closed.map(\.id) == [subject.id])
    #expect(await runtime.read()?.phase == .stopped)
    #expect(await runtime.read()?.sessions.map(\.sessionID) == [subject.id])

    // Opening again, over the same store and the same document.
    let second = makeWorkspace(
      sessions: [], runtime: runtime, repository: repository, processIdentifier: 4_243)
    await second.model.load()

    #expect(second.launcher.isRunning(subject.id))
    let restored = await repository.session(id: subject.id)
    #expect(restored?.status == .active)
    #expect(restored?.agent?.resumeIdentifier == "kept-identifier")
    #expect(restored?.repositories.first?.path == path)
    #expect(restored?.name == subject.name)
  }
}

// MARK: - Doubles

private actor MutableRepository: SessionRepository {
  private var stored: [WorkSession]

  init(sessions: [WorkSession]) {
    stored = sessions
  }

  func status(of id: SessionID) -> SessionStatus? {
    stored.first { $0.id == id }?.status
  }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? { stored.first { $0.id == id } }

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

/// A system whose processes the test decides on.
private final class StubProcesses: ProcessLivenessProbe, @unchecked Sendable {
  private let lock = NSLock()
  private let alive: Set<Int32>
  private var killed: [Int32] = []

  init(alive: Set<Int32> = []) {
    self.alive = alive
  }

  var terminated: [Int32] {
    lock.withLock { killed }
  }

  func isAlive(processIdentifier: Int32) -> Bool { alive.contains(processIdentifier) }

  /// Never answered: every recorded group is therefore unidentifiable, which is the case that
  /// must be reported rather than signalled.
  func startTime(of processIdentifier: Int32) -> Date? { nil }

  @discardableResult
  func terminate(processGroup: Int32) -> Bool {
    lock.withLock { killed.append(processGroup) }
    return true
  }
}

private actor SpySupervisor: TerminalSupervisor {
  private var sessions: [SessionID: FakeTerminalSession] = [:]

  func start(_ spec: TerminalSpec, for id: SessionID) throws -> any TerminalSession {
    let session = FakeTerminalSession(id: id, state: .running(processIdentifier: 4_242))
    sessions[id] = session
    return session
  }

  func session(for id: SessionID) -> (any TerminalSession)? { sessions[id] }

  func stop(id: SessionID, gracePeriod: Duration) async {
    await sessions.removeValue(forKey: id)?.finish(state: .exited(code: 0))
  }

  func stopAll(gracePeriod: Duration) async {
    let running = sessions.values
    sessions.removeAll()
    for session in running {
      await session.finish(state: .exited(code: 0))
    }
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
