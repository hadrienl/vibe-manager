import Foundation
import Observation
import VibeApplication
import VibeDomain
import VibeTerminalUI

/// Starts the terminal and the agent of a session, and keeps one pane per session alive.
///
/// The pane outlives a tab change on purpose: #8 needs each terminal to keep its state and its
/// scroll, and an agent must never be restarted just because the user looked at another session.
@MainActor
@Observable
public final class SessionLauncher {
  private let supervisor: any TerminalSupervisor
  private let repository: any SessionRepository
  private let agents: any AgentProviderResolving
  private let changeStatus: ChangeSessionStatus

  private var panes: [SessionID: TerminalPaneModel] = [:]
  private var observers: [SessionID: any AgentLaunchObserver] = [:]
  private var outputTasks: [SessionID: Task<Void, Never>] = [:]

  public init(
    supervisor: any TerminalSupervisor,
    repository: any SessionRepository,
    agents: any AgentProviderResolving,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.supervisor = supervisor
    self.repository = repository
    self.agents = agents
    changeStatus = ChangeSessionStatus(repository: repository, clock: clock)
  }

  public func pane(for id: SessionID) -> TerminalPaneModel? {
    panes[id]
  }

  public func isRunning(_ id: SessionID) -> Bool {
    panes[id]?.status == .running || panes[id]?.status == .starting
  }

  /// Starts one launch. Returns `true` once the process is running.
  ///
  /// A session that already has a running pane is left alone rather than started twice: pressing
  /// Create twice, or restoring a session that is already up, must not fork a second agent.
  @discardableResult
  public func launch(session: WorkSession, plan: AgentLaunchPlan) async -> Bool {
    guard !isRunning(session.id) else { return true }

    let pane = TerminalPaneModel(
      sessionID: session.id,
      supervisor: supervisor,
      spec: .agent(plan: plan)
    )
    panes[session.id] = pane
    await pane.start()

    guard let terminal = pane.session else { return false }

    await startObserver(for: session, plan: plan, terminal: terminal)
    // The session becomes active only now: it is stored closed, so a launch that never reached
    // a process leaves a session the user can retry rather than a lie about a running agent.
    _ = try? await changeStatus(id: session.id, action: .reopen)
    return true
  }

  public func failure(for id: SessionID) -> TerminalPaneModel.Failure? {
    panes[id]?.failure
  }

  public func stopAll(gracePeriod: Duration = .seconds(3)) async {
    for task in outputTasks.values {
      task.cancel()
    }
    outputTasks.removeAll()
    for observer in observers.values {
      await observer.finished()
    }
    observers.removeAll()
    await supervisor.stopAll(gracePeriod: gracePeriod)
  }

  private func startObserver(
    for session: WorkSession,
    plan: AgentLaunchPlan,
    terminal: any TerminalSession
  ) async {
    guard let providerID = session.agent?.providerID,
      let provider = await agents.provider(id: AgentProviderID(providerID)),
      let observing = provider as? any AgentLaunchObserverProviding
    else {
      return
    }

    let observer = observing.launchObserver(for: session.id, repository: repository)
    observers[session.id] = observer
    await observer.launched(plan: plan)

    outputTasks[session.id]?.cancel()
    outputTasks[session.id] = Task {
      let attachment = await terminal.attach()
      for await event in attachment.events {
        guard case .output(let bytes) = event else { continue }
        await observer.observe(output: String(decoding: bytes, as: UTF8.self))
      }
      await observer.finished()
    }
  }
}
