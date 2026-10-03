import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// What the launcher holds for a session's process is let go of on every path its run ends by
/// (#255): nothing grows with each session run.
@MainActor
@Suite("Forgetting a session's process state")
struct SessionLauncherRuntimeTests {
  private func plan() -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: AgentProviderID("stub"), executablePath: "/usr/bin/true", arguments: [],
      environment: [:], workingDirectoryPath: "/workspace", promptDelivery: .none)
  }

  private func session(_ name: String) -> WorkSession {
    WorkSession(
      name: name, agent: SessionAgentConfiguration(providerID: "stub"), status: .closed,
      repositories: [RepositoryContext(path: "/workspace")])
  }

  private func launcher(
    _ sessions: [WorkSession], supervisor: OutputSupervisor
  ) -> SessionLauncher {
    SessionLauncher(
      supervisor: supervisor, repository: StoredSessions(sessions), agents: NoAgents(),
      activity: TrackAgentActivity(logs: NoActivityLogs(), store: NoActivityStore()),
      viewportTimeout: .zero)
  }

  @Test("Detached, ended on its own, or all stopped: nothing stays tracked")
  func everyEndForgets() async {
    let detached = session("Detached")
    let ended = session("Ended")
    let stopped = session("Stopped")
    let supervisor = OutputSupervisor()
    let launcher = launcher([detached, ended, stopped], supervisor: supervisor)
    for session in [detached, ended, stopped] {
      await launcher.launch(session: session, plan: plan())
    }
    // What the terminal last wrote is the terminal's to note, not the launcher's (#248): what the
    // launcher holds is its readers, its observer and when each process started.
    await waitUntil("the three runs tracked") {
      Set([detached, ended, stopped].map(\.id)).isSubset(of: launcher.trackedSessionIDs)
    }

    _ = await launcher.detach(detached.id)
    #expect(!launcher.trackedSessionIDs.contains(detached.id))

    await supervisor.emit(.stateChanged(.exited(code: 0)), to: ended.id)
    await waitUntil("the process that ended forgotten") {
      !launcher.trackedSessionIDs.contains(ended.id)
    }

    await launcher.stopAll(gracePeriod: .zero)
    #expect(launcher.trackedSessionIDs.isEmpty)
  }

  @Test("Stopping every agent, to quit or to update, is a stop asked for: no error is read (#235)")
  func stopAllIsOnPurpose() async {
    let session = session("Quitting")
    let supervisor = OutputSupervisor()
    let launcher = launcher([session], supervisor: supervisor)
    await launcher.launch(session: session, plan: plan())
    let pane = launcher.pane(for: session.id)
    #expect(pane != nil)
    #expect(pane?.wasStoppedOnPurpose == false)

    await launcher.stopAll(gracePeriod: .zero)

    #expect(pane?.wasStoppedOnPurpose == true)
  }
}

private actor StoredSessions: SessionRepository {
  private var stored: [WorkSession]

  init(_ sessions: [WorkSession]) {
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

/// Terminals whose every attachment hears what the test makes them say.
private actor OutputSupervisor: TerminalSupervisor {
  private var sessions: [TerminalID: ScriptedTerminal] = [:]

  func start(_ spec: TerminalSpec, for id: TerminalID) throws -> any TerminalSession {
    let session = ScriptedTerminal(id: id)
    sessions[id] = session
    return session
  }

  func session(for id: TerminalID) -> (any TerminalSession)? { sessions[id] }

  func stop(id: TerminalID, gracePeriod: Duration) {}

  func stopAll(gracePeriod: Duration) {}

  func emit(_ event: TerminalEvent, to id: SessionID) async {
    await sessions[id.agentTerminal]?.emit(event)
  }
}

private actor ScriptedTerminal: TerminalSession {
  nonisolated let id: TerminalID
  private var current = TerminalProcessState.running(processIdentifier: 4242)
  private var listeners: [AsyncStream<TerminalEvent>.Continuation] = []

  init(id: TerminalID) {
    self.id = id
  }

  func attach() -> TerminalAttachment {
    let (events, continuation) = AsyncStream<TerminalEvent>.makeStream()
    listeners.append(continuation)
    return TerminalAttachment(
      state: current, history: TerminalHistorySnapshot(bytes: [], droppedByteCount: 0),
      events: events)
  }

  func emit(_ event: TerminalEvent) {
    if case .stateChanged(let state) = event { current = state }
    for listener in listeners { listener.yield(event) }
  }

  func state() -> TerminalProcessState { current }

  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: [], droppedByteCount: 0)
  }

  func write(_ bytes: [UInt8]) {}

  func resize(to size: TerminalSize) {}

  func stop(gracePeriod: Duration) {
    emit(.stateChanged(.terminated(signal: 15)))
  }

  func kill() {
    emit(.stateChanged(.terminated(signal: 9)))
  }
}

private struct NoAgents: AgentProviderResolving {
  func descriptors() async -> [AgentDescriptor] { [] }
  func provider(id: AgentProviderID) async -> (any AgentProvider)? { nil }
  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] { [:] }
}

private actor NoActivityLogs: AgentActivityLogStore {
  func prepareLog(for id: SessionID) -> URL { URL(fileURLWithPath: "/tmp/\(id).log") }
  func existingLog(for id: SessionID) -> URL? { nil }
  func end(for id: SessionID) -> AgentActivityLogPosition? { nil }
  func events(for id: SessionID, from position: AgentActivityLogPosition?)
    -> AsyncStream<(AgentActivityEvent, AgentActivityLogPosition)>
  { AsyncStream { $0.finish() } }
  func removeLog(for id: SessionID) {}
}

private actor NoActivityStore: AgentActivityStateStore {
  func read() -> [SessionID: PersistedAgentActivity] { [:] }
  func write(_ activities: [SessionID: PersistedAgentActivity]) {}
}
