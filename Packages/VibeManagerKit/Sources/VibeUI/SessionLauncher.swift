import Foundation
import Observation
import VibeApplication
import VibeDomain
import VibeTerminalUI

/// Starts the terminal and the agent of a session, and keeps one pane per session alive.
///
/// The pane outlives a tab change on purpose: #8 needs each terminal to keep its state and its
/// scroll, and an agent must never be restarted just because the user looked at another session.
/// What a start attempt did, rather than whether it "worked".
///
/// The distinction that matters is the middle one: a session that turned out to be running
/// already was not started, and is not a failure either — reported as one it produced an error
/// banner over a perfectly healthy agent.
public enum SessionStartOutcome: Equatable, Sendable {
  case started
  case alreadyRunning
  /// `reason` is filled when the launcher knows something the pane cannot say — because the pane
  /// was released, or because nothing was ever wrong with the terminal itself.
  case failed(reason: String?)

  public var isRunningNow: Bool {
    switch self {
    case .started, .alreadyRunning: return true
    case .failed: return false
    }
  }
}

@MainActor
@Observable
public final class SessionLauncher: SessionRuntime, SessionRestarting, SessionHandOff {
  private let supervisor: any TerminalSupervisor
  private let repository: any SessionRepository
  private let agents: any AgentProviderResolving
  private let changeStatus: ChangeSessionStatus
  /// Where what is running is written down, for the next launch to read. Absent in a workspace
  /// assembled without the system around it, and the launcher then simply keeps no record.
  private let recorder: SessionRuntimeRecorder?

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
  /// Called with the state the process actually ended in.
  ///
  /// The state travels with the callback rather than being read back from the pane: the pane is
  /// driven by its own attachment, on its own task, and a listener that asked it what happened
  /// could be told "still running" about a process that had already exited.
  public var sessionDidClose: (@MainActor (SessionID, TerminalProcessState) -> Void)?

  /// How long a launch waits for the pane to measure itself before falling back to the spec's
  /// own size. Long enough for one layout pass, short enough never to feel like a delay.
  private let viewportTimeout: Duration

  public init(
    supervisor: any TerminalSupervisor,
    repository: any SessionRepository,
    agents: any AgentProviderResolving,
    recorder: SessionRuntimeRecorder? = nil,
    clock: any SessionClock = SystemSessionClock(),
    viewportTimeout: Duration = .milliseconds(500)
  ) {
    self.supervisor = supervisor
    self.repository = repository
    self.agents = agents
    self.recorder = recorder
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
    await start(session: session, plan: plan, notice: nil).isRunningNow
  }

  /// - Parameter notice: a line written into the terminal just above the process, for a restart.
  ///   It travels with the launch rather than being posted beforehand, because posting it would
  ///   mean creating the pane first — and a pane that exists but has never started reads as
  ///   `starting`, which is exactly what this method refuses to start over.
  private func start(
    session: WorkSession,
    plan: AgentLaunchPlan,
    notice: String?
  ) async -> SessionStartOutcome {
    // An archived session is out of reach by design. Refusing here, rather than only hiding the
    // command, is what lets #10's Restart and #11's restore walk the whole store without having
    // to remember the rule — and it is how "no process stays attached" survives their arrival.
    guard session.status != .archived else { return .failed(reason: Self.archivedReason) }
    guard !isRunning(session.id) else { return .alreadyRunning }
    // Asked of the store rather than of the value the caller holds. Between the moment a restart
    // read its session and the moment it gets here there is a detection and a launch plan, and a
    // session archived in that window would otherwise be handed a brand new process.
    if let current = try? await repository.session(id: session.id), current.status == .archived {
      return .failed(reason: Self.archivedReason)
    }

    // The pane a session already has is reused rather than replaced. The view that renders it
    // is keyed on the session id, so SwiftUI would keep its coordinator — and its keyboard and
    // resize wiring — pointed at a pane nobody renders any more.
    let pane = pane(for: session.id) ?? makePane(for: session.id, plan: plan)
    if let notice {
      pane.post(notice: notice)
    }
    await pane.start(spec: .agent(plan: plan))

    guard let terminal = pane.session else {
      // The separator announced a process that never started. Left queued it would be shown above
      // the *next* one, dating a restart that did not happen.
      _ = pane.takePendingNotice()
      // The pane is kept, and it holds why: no reason is carried here, so the failure the user
      // reads is the terminal's own rather than a second, vaguer sentence over it.
      return .failed(reason: nil)
    }

    // The session becomes active before anything is armed on it: it is stored closed until a
    // process exists, so a launch that never reached one leaves a session the user can retry
    // rather than a lie about a running agent — and a watch armed first would have nothing to
    // close. A process that has already ended by now would run its watch during the observer's
    // own await, find the session still closed, and leave it listed as running for good.
    // `reopen` is legal only from `closed`, so its refusal is how the store says the session went
    // somewhere else while this launch was under way — or that the write itself failed. Only one
    // of those is harmless: the session is already active, because another path opened it first.
    // Every other refusal is let through at the cost of a live process attached to a session the
    // store still calls closed, which the exit's own `close` then fails to reconcile as well.
    if (try? await changeStatus(id: session.id, action: .reopen)) == nil {
      let current = (try? await repository.session(id: session.id)) ?? nil
      guard current?.status == .active else {
        await dispose(session.id)
        return .failed(
          reason: current?.status == .archived ? Self.archivedReason : Self.storeRefusedReason
        )
      }
    }
    watchForExit(id: session.id, terminal: terminal)
    await startObserver(for: session, plan: plan, terminal: terminal)
    // Recorded once there is something to record, and from the terminal rather than from the
    // plan: the process group is the child's own pid, which only exists after the spawn. A
    // process that has already ended by now leaves no record, which is the truth — there is
    // nothing left to look for at the next launch.
    if case .running(let processIdentifier) = await terminal.state() {
      await recorder?.started(session.id, processGroup: processIdentifier)
    }
    return .started
  }

  /// The port #11 restores through. One road to a process, and this is the door on it.
  public func attemptRestart(_ restart: SessionRestart) async -> SessionRestartAttempt {
    switch await self.restart(restart) {
    case .started, .alreadyRunning:
      return .started
    case .failed(let reason):
      let failure = failure(for: restart.session.id)
      return SessionRestartAttempt(
        started: false,
        message: reason ?? failure?.message ?? "This session could not be restarted.",
        suggestion: reason == nil ? failure?.suggestion : nil
      )
    }
  }

  static let archivedReason = "This session is archived."
  static let storeRefusedReason = "The session store would not put this session back to work."

  /// Starts a closed session again, in the pane it already has.
  ///
  /// The pane is reused rather than rebuilt, so what the previous agent said stays on screen
  /// above what the next one will say — that is what "restarting keeps its context" looks like
  /// to the person watching. A dated separator is written between the two: without it, two runs
  /// of an agent share one buffer and yesterday's output reads as today's.
  /// A session that turns out to be running already answers `alreadyRunning`, not a failure: the
  /// agent the user asked for is up, and reporting that as an error put a banner over it.
  @discardableResult
  public func restart(_ restart: SessionRestart, at date: Date = Date())
    async -> SessionStartOutcome
  {
    await start(
      session: restart.session,
      plan: restart.plan,
      notice: Self.separator(for: restart.mode, at: date)
    )
  }

  /// Starts the agent a session was just switched to, in the pane it already has.
  ///
  /// `session` is the one read back after the switch was recorded, so that everything the start
  /// consults — the observer, the record — already names the new agent.
  @discardableResult
  public func launchSwitch(
    _ plan: AgentSwitchPlan,
    session: WorkSession,
    previous: String,
    at date: Date = Date()
  ) async -> SessionStartOutcome {
    await start(
      session: session,
      plan: plan.plan,
      notice: Self.switchSeparator(for: plan, previous: previous, at: date)
    )
  }

  /// The line written into the terminal above the agent a session was switched to.
  ///
  /// It names both agents: the output above it is the previous one's, and without the line the
  /// user would read it as the new agent's own.
  static func switchSeparator(
    for plan: AgentSwitchPlan,
    previous: String,
    at date: Date
  ) -> String {
    let stamp = date.formatted(date: .abbreviated, time: .shortened)
    let what: String
    switch plan.mode {
    case .resumeWithModel: what = "same conversation"
    case .firstLaunch: what = "first start"
    case .handover: what = "given a summary"
    case .freshWithoutContext: what = "new process"
    }
    let next = plan.target.modelID.map { "\(plan.targetName) (\($0))" } ?? plan.targetName
    let title =
      plan.session.agent?.providerID == plan.target.providerID ? "Model changed" : "Agent switched"
    return "\r\n\u{1B}[2m── \(title) · \(stamp) · \(previous) → \(next) · \(what) ──\u{1B}[0m\r\n"
  }

  /// The line written into the terminal above a restarted process.
  ///
  /// Dim, on its own lines, and it says which of the three restarts this was: a user who reads
  /// "new process" knows the agent above has not been told any of it.
  static func separator(for mode: SessionRestartMode, at date: Date) -> String {
    let stamp = date.formatted(date: .abbreviated, time: .shortened)
    let what: String
    switch mode {
    case .firstLaunch:
      what = "first start"
    case .native:
      what = "resumed conversation"
    case .freshWithContext:
      what = "new process, given a summary"
    case .freshWithoutContext:
      what = "new process"
    }
    return "\r\n\u{1B}[2m── Restart · \(stamp) · \(what) ──\u{1B}[0m\r\n"
  }

  /// Takes back a session whose process the terminal host kept while the application was closed,
  /// or one that ended in the meantime, to show its last output.
  ///
  /// Nothing is launched and nothing is written to the store: a running session is still `active`
  /// there, and one that ended was closed by the detection that found it. No agent observer is
  /// started either — it needs the launch plan, which only the launch had — so an identifier the
  /// agent had not yet written by the time the application quit is not captured afterwards.
  @discardableResult
  public func adopt(_ session: WorkSession) async -> Bool {
    guard let terminal = await supervisor.session(for: session.id) else { return false }
    let pane = pane(for: session.id) ?? makePane(for: session.id, spec: nil)
    await pane.adopt(terminal)
    guard case .running(let processIdentifier) = await terminal.state() else { return true }
    watchForExit(id: session.id, terminal: terminal)
    await recorder?.started(session.id, processGroup: processIdentifier)
    return true
  }

  /// How many sessions are running in the terminal host, and so could be left running on quit.
  public var hostedRunningCount: Int {
    panes.values.filter { pane in
      (pane.status == .running || pane.status == .starting) && pane.session is any HostedTerminal
    }.count
  }

  // MARK: - SessionHandOff

  /// Lets go of a session without stopping it, when the terminal host runs it.
  ///
  /// Its exit watch is retired, so the store is not told of an exit nobody here will see, and its
  /// observer is finished. The record of its process group stays: it is what the next launch looks
  /// for if the host turns out to be gone.
  public func handOff(_ id: SessionID) async -> Bool {
    guard let terminal = panes[id]?.session, terminal is any HostedTerminal,
      await !terminal.state().isFinished
    else { return false }
    exitTasks.removeValue(forKey: id)?.cancel()
    _ = nextExitGeneration(for: id)
    outputTasks.removeValue(forKey: id)?.cancel()
    if let observer = observers.removeValue(forKey: id) {
      await observer.finished()
    }
    return true
  }

  private func makePane(for id: SessionID, plan: AgentLaunchPlan) -> TerminalPaneModel {
    makePane(for: id, spec: .agent(plan: plan))
  }

  private func makePane(for id: SessionID, spec: TerminalSpec?) -> TerminalPaneModel {
    let pane = TerminalPaneModel(
      sessionID: id,
      supervisor: supervisor,
      spec: spec,
      viewportTimeout: viewportTimeout
    )
    panes[id] = pane
    return pane
  }

  public func failure(for id: SessionID) -> TerminalPaneModel.Failure? {
    panes[id]?.failure
  }

  public func stopAll(gracePeriod: Duration = .seconds(3)) async {
    // Retired as well as cancelled, exactly as `detach` does: a watch already on its way to the
    // main actor would otherwise still write to the store and ask for a reload, during teardown.
    for (id, task) in exitTasks {
      _ = nextExitGeneration(for: id)
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
    var wasAlreadyUnreachable = false
    if let terminal {
      let state = await terminal.state()
      wasRunning = !state.isFinished
      if case .failed(.processOutcomeUnknown) = state { wasAlreadyUnreachable = true }
    }

    if let pane {
      await pane.stop()
    } else {
      await supervisor.stop(id: id, gracePeriod: .seconds(3))
    }
    // The record is dropped only once the process really is stopped. Dropped beforehand, a
    // `SIGKILL` landing inside the grace period would leave a live process group whose
    // identifiers have just been erased: nothing to look for at the next launch, and nothing to
    // tell the user about.
    await recorder?.stopped(id)

    // Asked before "was it running": a terminal whose group could not be reaped is already
    // finished, so answering `wasNotRunning` first would drop the warning on exactly the session
    // that still has a process behind it.
    //
    // Only when this call is the one that left it there. A terminal parked in that state by an
    // earlier close has already had its warning; repeating it on the archive would claim a stop
    // that was never attempted, against a process that may have been gone for hours.
    if let terminal, !wasAlreadyUnreachable,
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
      var finalState = attachment.state
      if !finalState.isFinished {
        for await event in attachment.events {
          guard case .stateChanged(let state) = event, state.isFinished else { continue }
          finalState = state
          break
        }
      }
      // The stream can end without ever announcing the finish — a terminal released under it.
      // Asking the session itself is the last word, and it is asked once, here.
      if !finalState.isFinished {
        finalState = await terminal.state()
      }
      guard !Task.isCancelled else { return }
      await self?.processDidFinish(id, generation: generation, state: finalState)
    }
  }

  private func nextExitGeneration(for id: SessionID) -> Int {
    let generation = (exitGenerations[id] ?? 0) + 1
    exitGenerations[id] = generation
    return generation
  }

  private func processDidFinish(
    _ id: SessionID,
    generation: Int,
    state: TerminalProcessState
  ) async {
    // The watch that reaches this point may have been superseded while it waited for the main
    // actor — by a detach, or by a relaunch that installed its own. Only the current one speaks.
    guard exitGenerations[id] == generation else { return }
    await recorder?.stopped(id)
    // Asked again after every suspension: a switch can stop, record and relaunch the session
    // while this watch waits, and what follows would then finish the *new* agent's observer,
    // close the session under it and report its exit.
    guard exitGenerations[id] == generation else { return }
    exitTasks[id] = nil
    outputTasks.removeValue(forKey: id)?.cancel()
    if let observer = observers.removeValue(forKey: id) {
      await observer.finished()
    }
    guard exitGenerations[id] == generation else { return }
    // A session that was never marked active — a launch that failed — has nothing to close, and
    // `close` says so by refusing the transition rather than by inventing a second rule here.
    _ = try? await changeStatus(id: id, action: .close)
    guard exitGenerations[id] == generation else { return }
    sessionDidClose?(id, state)
  }

  private func startObserver(
    for session: WorkSession,
    plan: AgentLaunchPlan,
    terminal: any TerminalSession
  ) async {
    // The plan names the agent that is actually starting. The stored agent said the same until
    // agents could be switched; now the plan is the one fact that cannot lag behind.
    guard let provider = await agents.provider(id: plan.providerID),
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
