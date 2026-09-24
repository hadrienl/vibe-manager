import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

// Taking back what the terminal host kept while the application was closed, and letting go of it
// on the way out (ADR 0017).

/// A terminal that runs in the host, as far as the launcher can tell.
private actor HostedWorkspaceTerminal: HostedTerminal {
  nonisolated let id: SessionID
  private var current: TerminalProcessState
  private var continuations: [AsyncStream<TerminalEvent>.Continuation] = []
  private let output: [UInt8]

  init(id: SessionID, state: TerminalProcessState, output: String = "") {
    self.id = id
    current = state
    self.output = Array(output.utf8)
  }

  func attach() -> TerminalAttachment {
    var continuation: AsyncStream<TerminalEvent>.Continuation?
    let events = AsyncStream<TerminalEvent> { continuation = $0 }
    if let continuation {
      if current.isFinished {
        continuation.finish()
      } else {
        continuations.append(continuation)
      }
    }
    return TerminalAttachment(
      state: current,
      history: TerminalHistorySnapshot(bytes: output, droppedByteCount: 0),
      events: events
    )
  }

  func state() -> TerminalProcessState { current }

  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: output, droppedByteCount: 0)
  }

  func write(_ bytes: [UInt8]) {}

  func resize(to size: TerminalSize) {}

  func stop(gracePeriod: Duration) { finish(state: .exited(code: 0)) }

  func kill() { finish(state: .terminated(signal: 9)) }

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

/// A supervisor that already holds terminals, as one does after reconnecting to the host.
private actor HostSupervisor: TerminalSupervisor, TerminalHosting {
  private var terminals: [SessionID: HostedWorkspaceTerminal]
  private(set) var startCount = 0

  init(_ terminals: [HostedWorkspaceTerminal]) {
    self.terminals = Dictionary(uniqueKeysWithValues: terminals.map { ($0.id, $0) })
  }

  func start(_ spec: TerminalSpec, for id: SessionID) throws -> any TerminalSession {
    startCount += 1
    let terminal = HostedWorkspaceTerminal(id: id, state: .running(processIdentifier: 7))
    terminals[id] = terminal
    return terminal
  }

  func session(for id: SessionID) -> (any TerminalSession)? { terminals[id] }

  func stop(id: SessionID, gracePeriod: Duration) async {
    await terminals[id]?.finish(state: .exited(code: 0))
  }

  func stopAll(gracePeriod: Duration) {}

  func reconnect() async -> TerminalHostStatus {
    var summaries: [HostedSessionSummary] = []
    for terminal in terminals.values {
      let state = await terminal.state()
      summaries.append(
        HostedSessionSummary(
          id: terminal.id, state: state,
          endedAt: state.isFinished ? Date(timeIntervalSince1970: 1_700_003_000) : nil))
    }
    return .connected(
      TerminalHostIdentity(processIdentifier: 815, processStartedAt: nil), sessions: summaries)
  }

  func hostIdentity() -> TerminalHostIdentity? { nil }

  func discard(_ id: SessionID) {}

  func relinquish(keepRunning: Bool) {}
}

/// A host that will not serve until the test lets it.
private actor ReluctantHost: TerminalHosting {
  private var isAvailable = false
  private let running: SessionID

  init(running: SessionID) {
    self.running = running
  }

  func open() { isAvailable = true }

  func reconnect() -> TerminalHostStatus {
    guard isAvailable else { return .unavailable(reason: "The terminal host did not answer.") }
    return .connected(
      TerminalHostIdentity(processIdentifier: 815, processStartedAt: nil),
      sessions: [HostedSessionSummary(id: running, state: .running(processIdentifier: 902))])
  }

  func hostIdentity() -> TerminalHostIdentity? { nil }

  func discard(_ id: SessionID) {}

  func relinquish(keepRunning: Bool) {}
}

@MainActor
@Suite("Taking back the agents the terminal host kept")
struct SessionAdoptionTests {
  private func session(status: SessionStatus = .active) -> WorkSession {
    WorkSession(
      name: "Refactor the webhook",
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: "kept"),
      status: status,
      repositories: [RepositoryContext(path: "/workspace")]
    )
  }

  private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<250 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
  }

  @Test("A running agent is shown as it is: nothing started, nothing written to the store")
  func adoptsARunningAgent() async {
    let stored = session()
    let terminal = HostedWorkspaceTerminal(
      id: stored.id, state: .running(processIdentifier: 902), output: "halfway through")
    let supervisor = HostSupervisor([terminal])
    let repository = WorkspaceRepository(sessions: [stored])
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: WorkspaceRegistry(providers: []),
      viewportTimeout: .zero)

    #expect(await launcher.adopt(stored))

    #expect(launcher.isRunning(stored.id))
    #expect(launcher.hostedRunningCount == 1)
    #expect(!launcher.willStopWithApplication(stored.id))
    #expect(await supervisor.startCount == 0)
    #expect(await repository.status(of: stored.id) == .active)
  }

  @Test("An adopted agent that ends closes its session, as any agent does")
  func adoptedExitClosesTheSession() async {
    let stored = session()
    let terminal = HostedWorkspaceTerminal(id: stored.id, state: .running(processIdentifier: 902))
    let repository = WorkspaceRepository(sessions: [stored])
    let launcher = SessionLauncher(
      supervisor: HostSupervisor([terminal]), repository: repository,
      agents: WorkspaceRegistry(providers: []), viewportTimeout: .zero)
    await launcher.adopt(stored)

    await terminal.finish(state: .exited(code: 0))

    #expect(await eventually { await repository.status(of: stored.id) == .closed })
  }

  @Test("Handed off on the way out, an agent's exit is no longer this launch's to record")
  func handOffRetiresTheExitWatch() async {
    let stored = session()
    let terminal = HostedWorkspaceTerminal(id: stored.id, state: .running(processIdentifier: 902))
    let repository = WorkspaceRepository(sessions: [stored])
    let launcher = SessionLauncher(
      supervisor: HostSupervisor([terminal]), repository: repository,
      agents: WorkspaceRegistry(providers: []), viewportTimeout: .zero)
    await launcher.adopt(stored)

    #expect(await launcher.handOff(stored.id))
    await terminal.finish(state: .exited(code: 0))
    try? await Task.sleep(for: .milliseconds(200))

    #expect(await repository.status(of: stored.id) == .active)
  }

  @Test("A terminal that runs in the application cannot be handed off")
  func localTerminalsAreNotHandedOff() async {
    let stored = session(status: .closed)
    let repository = WorkspaceRepository(sessions: [stored])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository,
      agents: WorkspaceRegistry(providers: []), viewportTimeout: .zero)
    let plan = AgentLaunchPlan(
      providerID: AgentProviderID("stub"),
      executablePath: "/usr/bin/true",
      arguments: [],
      environment: [:],
      workingDirectoryPath: "/workspace",
      promptDelivery: .none
    )
    await launcher.launch(session: stored, plan: plan)

    #expect(launcher.isRunning(stored.id))
    #expect(launcher.hostedRunningCount == 0)
    #expect(launcher.willStopWithApplication(stored.id))
    #expect(launcher.inProcessRunningCount == 1)
    #expect(await launcher.handOff(stored.id) == false)
  }

  @Test("A host that would not answer is said so, nothing is touched, and Retry takes them back")
  func retriesAnUnavailableHost() async {
    let running = session()
    let host = ReluctantHost(running: running.id)
    let supervisor = HostSupervisor([
      HostedWorkspaceTerminal(id: running.id, state: .running(processIdentifier: 902))
    ])
    let repository = WorkspaceRepository(sessions: [running])
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: WorkspaceRegistry(providers: []),
      viewportTimeout: .zero)
    let store = EphemeralSessionRuntimeStateStore(
      state: SessionRuntimeState(
        phase: .detached,
        processIdentifier: 1_001,
        launchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_600),
        stoppedAt: Date(timeIntervalSince1970: 1_700_000_600),
        sessions: [SessionRuntimeRecord(sessionID: running.id)]
      ))
    let model = AppModel(
      repository: repository,
      agents: WorkspaceRegistry(providers: []),
      launcher: launcher,
      runtimeRecorder: SessionRuntimeRecorder(store: store, processIdentifier: 4242),
      terminalHost: host
    )

    await model.load()

    #expect(model.hostUnavailableReason == "The terminal host did not answer.")
    #expect(await repository.status(of: running.id) == .active)
    #expect(await store.read()?.phase == .detached)
    #expect(!launcher.isRunning(running.id))

    await host.open()
    await model.retryHostReattach()

    #expect(model.hostUnavailableReason == nil)
    #expect(model.detachedNotice == AppModel.DetachedNotice(runningCount: 1, endedCount: 0))
    #expect(launcher.isRunning(running.id))
    #expect(await store.read()?.phase == .running)
  }

  @Test("At launch, agents left running are back on screen and said to have kept running")
  func launchReattaches() async {
    let running = session()
    let ended = session()
    let supervisor = HostSupervisor([
      HostedWorkspaceTerminal(id: running.id, state: .running(processIdentifier: 902)),
      HostedWorkspaceTerminal(id: ended.id, state: .exited(code: 0), output: "done"),
    ])
    let repository = WorkspaceRepository(sessions: [running, ended])
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: WorkspaceRegistry(providers: []),
      viewportTimeout: .zero)
    let recorder = SessionRuntimeRecorder(
      store: EphemeralSessionRuntimeStateStore(
        state: SessionRuntimeState(
          phase: .detached,
          processIdentifier: 1_001,
          launchedAt: Date(timeIntervalSince1970: 1_700_000_000),
          updatedAt: Date(timeIntervalSince1970: 1_700_000_600),
          stoppedAt: Date(timeIntervalSince1970: 1_700_000_600),
          sessions: [
            SessionRuntimeRecord(sessionID: running.id),
            SessionRuntimeRecord(sessionID: ended.id),
          ]
        )),
      processIdentifier: 4242
    )
    let model = AppModel(
      repository: repository,
      agents: WorkspaceRegistry(providers: []),
      launcher: launcher,
      runtimeRecorder: recorder,
      terminalHost: supervisor
    )

    await model.load()

    #expect(model.detachedNotice == AppModel.DetachedNotice(runningCount: 1, endedCount: 1))
    #expect(
      model.detachedNotice?.message
        == "2 agents kept running while Vibe Manager was closed; 1 has finished since.")
    #expect(launcher.isRunning(running.id))
    #expect(launcher.pane(for: ended.id)?.status == .exited(code: 0))
    #expect(await repository.status(of: running.id) == .active)
    #expect(await repository.status(of: ended.id) == .closed)
    #expect(await supervisor.startCount == 0)
  }
}
