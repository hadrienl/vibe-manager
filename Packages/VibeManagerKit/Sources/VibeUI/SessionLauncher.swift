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
public final class SessionLauncher: SessionRuntime {
  private let supervisor: any TerminalSupervisor
  private let repository: any SessionRepository
  private let agents: any AgentProviderResolving
  private let changeStatus: ChangeSessionStatus

  private var panes: [SessionID: TerminalPaneModel] = [:]
  private var observers: [SessionID: any AgentLaunchObserver] = [:]
  private var outputTasks: [SessionID: Task<Void, Never>] = [:]
  private var exitTasks: [SessionID: Task<Void, Never>] = [:]
  /// Which exit watch is the current one for a session.
  ///
  /// Cancelling a task only asks. A watch that has already seen its process end, and is waiting
  /// its turn on the main actor, will still run: without this counter it could close a session
  /// that has just been relaunched, or drop a newer watch's entry and leave it untrackable.
  private var exitGenerations: [SessionID: Int] = [:]

  /// Called once a session's own process has ended and the store has been told. The workspace
  /// uses it to refresh: an agent that typed `exit` must not leave a session listed as running.
  public var sessionDidClose: (@MainActor (SessionID) -> Void)?

  /// How long a launch waits for the pane to measure itself before falling back to the spec's
  /// own size. Long enough for one layout pass, short enough never to feel like a delay.
  private let viewportTimeout: Duration

  public init(
    supervisor: any TerminalSupervisor,
    repository: any SessionRepository,
    agents: any AgentProviderResolving,
    clock: any SessionClock = SystemSessionClock(),
    viewportTimeout: Duration = .milliseconds(500)
  ) {
    self.supervisor = supervisor
    self.repository = repository
    self.agents = agents
    self.viewportTimeout = viewportTimeout
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
    // An archived session is out of reach by design. Refusing here, rather than only hiding the
    // command, is what lets #10's Restart and #11's restore walk the whole store without having
    // to remember the rule — and it is how "no process stays attached" survives their arrival.
    guard session.status != .archived else { return false }
    guard !isRunning(session.id) else { return true }

    // The pane a session already has is reused rather than replaced. The view that renders it
    // is keyed on the session id, so SwiftUI would keep its coordinator — and its keyboard and
    // resize wiring — pointed at a pane nobody renders any more.
    let pane = pane(for: session.id) ?? makePane(for: session.id, plan: plan)
    await pane.start(spec: .agent(plan: plan))

    guard let terminal = pane.session else { return false }

    watchForExit(id: session.id, terminal: terminal)
    await startObserver(for: session, plan: plan, terminal: terminal)
    // The session becomes active only now: it is stored closed, so a launch that never reached
    // a process leaves a session the user can retry rather than a lie about a running agent.
    _ = try? await changeStatus(id: session.id, action: .reopen)
    return true
  }

  private func makePane(for id: SessionID, plan: AgentLaunchPlan) -> TerminalPaneModel {
    let pane = TerminalPaneModel(
      sessionID: id,
      supervisor: supervisor,
      spec: .agent(plan: plan),
      viewportTimeout: viewportTimeout
    )
    panes[id] = pane
    return pane
  }

  public func failure(for id: SessionID) -> TerminalPaneModel.Failure? {
    panes[id]?.failure
  }

  public func stopAll(gracePeriod: Duration = .seconds(3)) async {
    for task in exitTasks.values {
      task.cancel()
    }
    exitTasks.removeAll()
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

  // MARK: - SessionRuntime

  /// Lets go of everything this session was attached to: its exit watch, its output reader, its
  /// agent observer and its process. The pane stays, so a closed session is still readable.
  ///
  /// The outcome is read back from the terminal rather than assumed. A process group the kernel
  /// would not let go of leaves the session in `processOutcomeUnknown`, and saying "stopped"
  /// there would be exactly the lie the archive is not allowed to tell.
  public func detach(_ id: SessionID) async -> SessionDetachOutcome {
    exitTasks.removeValue(forKey: id)?.cancel()
    // Retires the watch as well as cancelling it: one already on its way to the main actor is
    // past the point where cancellation can stop it.
    _ = nextExitGeneration(for: id)
    outputTasks.removeValue(forKey: id)?.cancel()
    if let observer = observers.removeValue(forKey: id) {
      await observer.finished()
    }

    let pane = panes[id]
    var terminal = pane?.session
    if terminal == nil {
      terminal = await supervisor.session(for: id)
    }

    var wasRunning = false
    if let terminal {
      wasRunning = !(await terminal.state().isFinished)
    }

    if let pane {
      await pane.stop()
    } else {
      await supervisor.stop(id: id, gracePeriod: .seconds(3))
    }

    // Asked before "was it running": a terminal whose group could not be reaped is already
    // finished, so answering `wasNotRunning` first would drop the warning on exactly the session
    // that still has a process behind it — an earlier close having left it in that state.
    if let terminal,
      case .failed(.processOutcomeUnknown(let processIdentifier)) = await terminal.state()
    {
      return .unreachable(processIdentifier: processIdentifier)
    }

    guard wasRunning else { return .wasNotRunning }
    return .stopped
  }

  /// Releases the pane itself, and with it the terminal's replay buffer. Only archiving does it.
  public func dispose(_ id: SessionID) async {
    _ = await detach(id)
    panes.removeValue(forKey: id)
  }

  /// A process that ends on its own closes its session, exactly as the command would.
  ///
  /// Without this, an agent that exits leaves a session stored `active` with nothing behind it:
  /// the sidebar would keep calling it running, and #11 would try to resume a session that has
  /// already had its say.
  private func watchForExit(id: SessionID, terminal: any TerminalSession) {
    exitTasks[id]?.cancel()
    let generation = nextExitGeneration(for: id)
    exitTasks[id] = Task { [weak self] in
      let attachment = await terminal.attach()
      if !attachment.state.isFinished {
        for await event in attachment.events {
          guard case .stateChanged(let state) = event, state.isFinished else { continue }
          break
        }
      }
      guard !Task.isCancelled else { return }
      await self?.processDidFinish(id, generation: generation)
    }
  }

  private func nextExitGeneration(for id: SessionID) -> Int {
    let generation = (exitGenerations[id] ?? 0) + 1
    exitGenerations[id] = generation
    return generation
  }

  private func processDidFinish(_ id: SessionID, generation: Int) async {
    // The watch that reaches this point may have been superseded while it waited for the main
    // actor — by a detach, or by a relaunch that installed its own. Only the current one speaks.
    guard exitGenerations[id] == generation else { return }
    exitTasks[id] = nil
    outputTasks.removeValue(forKey: id)?.cancel()
    if let observer = observers.removeValue(forKey: id) {
      await observer.finished()
    }
    // A session that was never marked active — a launch that failed — has nothing to close, and
    // `close` says so by refusing the transition rather than by inventing a second rule here.
    _ = try? await changeStatus(id: id, action: .close)
    sessionDidClose?(id)
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
      // One decoder for the whole stream: a read can end in the middle of a character, and the
      // identifiers the observer looks for would be broken by a replacement character.
      var decoder = UTF8StreamDecoder()
      for await event in attachment.events {
        guard case .output(let bytes) = event else { continue }
        let text = decoder.decode(bytes)
        guard !text.isEmpty else { continue }
        await observer.observe(output: text)
      }
      let tail = decoder.flush()
      if !tail.isEmpty {
        await observer.observe(output: tail)
      }
      await observer.finished()
    }
  }
}
