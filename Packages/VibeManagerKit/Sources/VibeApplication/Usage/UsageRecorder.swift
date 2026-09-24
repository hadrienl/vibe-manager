import Foundation
import VibeDomain

/// How a run started, as the launcher knows it.
public struct UsageRunContext: Hashable, Sendable {
  public var kind: UsageRunKind
  public var afterRelaunch: Bool
  public var afterSwitch: Bool

  public init(kind: UsageRunKind, afterRelaunch: Bool = false, afterSwitch: Bool = false) {
    self.kind = kind
    self.afterRelaunch = afterRelaunch
    self.afterSwitch = afterSwitch
  }
}

/// Writes the run journal: the only writer, so that one session has at most one open run.
///
/// It never sees a terminal's output. What it knows of a run is which session, which agent and
/// model, how it started and when it began and ended.
public actor UsageRecorder {
  private let ledger: any UsageLedger
  private let tracking: any UsageTrackingStore
  private let clock: any SessionClock
  private let heartbeatInterval: Duration

  /// One reading of the journal, shared by every caller that arrives before it is done.
  private var preparation: Task<Void, Never>?
  private var isEnabled = true
  /// Set when another copy of the application holds the data: the journal is its to write.
  private var isSealed = false
  private var isSettled = false
  /// The open run of each session.
  private var open: [SessionID: UsageRun] = [:]
  /// The runs the previous launch left open without handing them to the terminal host.
  private var leftovers: Set<UUID> = []
  /// The heartbeat the previous launch left, read before this one writes its own.
  private var previousHeartbeat: UsageHeartbeat?
  private var heartbeatTask: Task<Void, Never>?
  private var isAsleep = false
  /// Whether a `suspend` was written for the sleep under way, so its `resume` always is too.
  private var wroteSuspend = false
  /// The last write that failed, for the interface to say that some usage was not saved.
  public private(set) var lastWriteFailure: Date?

  public init(
    ledger: any UsageLedger,
    tracking: any UsageTrackingStore,
    clock: any SessionClock = SystemSessionClock(),
    heartbeatInterval: Duration = .seconds(60)
  ) {
    self.ledger = ledger
    self.tracking = tracking
    self.clock = clock
    self.heartbeatInterval = heartbeatInterval
  }

  /// Reads the journal and the tracking switch, once. Writes nothing: what the previous launch
  /// left open is only settled by `settleLaunch`, which a read-only copy never reaches.
  public func prepare() async {
    if let preparation { return await preparation.value }
    let task = Task { await self.load() }
    preparation = task
    await task.value
  }

  private func load() async {
    isEnabled = await tracking.intervals().isTracking
    previousHeartbeat = await ledger.heartbeat()
    let runs = UsageLedgerFold.runs(from: (try? await ledger.events()) ?? [])
    for run in runs where run.isOpen {
      open[run.sessionID] = run
      if run.detachedAt == nil { leftovers.insert(run.id) }
    }
  }

  /// Gives up writing: another copy of the application is working in these sessions (ADR 0011),
  /// and closing its runs from here would cut them short.
  public func seal() {
    isSealed = true
    heartbeatTask?.cancel()
    heartbeatTask = nil
  }

  /// Settles what the previous launch left open, once the terminal host has said what it kept.
  ///
  /// A run it never saw end is closed at the last heartbeat that names it, or at its own start. A
  /// run it left in the host goes on when its session runs again — it ran all along — and is
  /// otherwise closed when the detection closed its session, never before the hand-off and never
  /// after now.
  public func settleLaunch(running: Set<SessionID>, closedAt: [SessionID: Date]) async {
    await prepare()
    guard !isSealed, !isSettled else { return }
    isSettled = true
    let now = clock.now().storageRounded
    for (id, run) in open {
      if leftovers.contains(run.id) {
        await closeLeftover(run)
      } else if let detachedAt = run.detachedAt {
        if running.contains(id) {
          open[id]?.detachedAt = nil
          await write(.attach(runID: run.id, at: now))
        } else {
          let end = min(max(closedAt[id] ?? detachedAt, detachedAt), now)
          await write(.end(runID: run.id, at: end, exit: .endedWhileAway))
          open[id] = nil
        }
      }
    }
    await beat()
    updateHeartbeatTask()
  }

  private func closeLeftover(_ run: UsageRun) async {
    leftovers.remove(run.id)
    open[run.sessionID] = nil
    var end = run.startedAt
    if let heartbeat = previousHeartbeat, heartbeat.runIDs.contains(run.id) {
      end = max(heartbeat.at, run.startedAt)
    }
    await write(.end(runID: run.id, at: end, exit: .interrupted))
  }

  public func started(
    _ session: SessionID, providerID: String, modelID: String?, context: UsageRunContext
  ) async {
    await prepare()
    guard isEnabled, !isSealed else { return }
    let now = clock.now().storageRounded
    if let previous = open[session] {
      if leftovers.contains(previous.id) {
        await closeLeftover(previous)
      } else {
        await write(.end(runID: previous.id, at: max(now, previous.startedAt), exit: .stopped))
      }
    }
    let run = UsageRun(
      sessionID: session, providerID: providerID, modelID: modelID, kind: context.kind,
      afterRelaunch: context.afterRelaunch, afterSwitch: context.afterSwitch, startedAt: now)
    open[session] = run
    await write(.start(run))
    await beat()
    updateHeartbeatTask()
  }

  public func ended(_ session: SessionID, exit: UsageRunExit) async {
    await prepare()
    guard !isSealed, let run = open[session], !leftovers.contains(run.id) else { return }
    open[session] = nil
    await write(.end(runID: run.id, at: clock.now().storageRounded, exit: exit))
    await beat()
    updateHeartbeatTask()
  }

  /// The application quits and leaves this session's agent running in the terminal host.
  public func detached(_ session: SessionID) async {
    await prepare()
    guard !isSealed, let run = open[session], run.detachedAt == nil,
      !leftovers.contains(run.id)
    else { return }
    let now = clock.now().storageRounded
    open[session]?.detachedAt = now
    await write(.detach(runID: run.id, at: now))
    await beat()
    updateHeartbeatTask()
  }

  public func systemWillSleep() async {
    await prepare()
    guard !isAsleep else { return }
    isAsleep = true
    guard !isSealed, !liveRuns.isEmpty else { return }
    wroteSuspend = true
    await write(.suspend(at: clock.now().storageRounded))
  }

  public func systemDidWake() async {
    await prepare()
    guard isAsleep else { return }
    isAsleep = false
    // Written whenever the sleep was: a run that ended in between must not leave the sleep open.
    guard wroteSuspend else { return }
    wroteSuspend = false
    await write(.resume(at: clock.now().storageRounded))
    await beat()
  }

  public func isTracking() async -> Bool {
    await prepare()
    return isEnabled
  }

  /// Turning tracking off closes what runs now: what follows is not counted. Turning it back on
  /// counts agents from their next start.
  public func setTracking(_ enabled: Bool) async {
    await prepare()
    guard enabled != isEnabled, !isSealed else { return }
    let now = clock.now().storageRounded
    var intervals = await tracking.intervals()
    if enabled {
      intervals.append(UsageTrackingInterval(from: now))
    } else {
      if let last = intervals.indices.last, intervals[last].to == nil { intervals[last].to = now }
      for (id, run) in open where run.detachedAt == nil && !leftovers.contains(run.id) {
        await write(.end(runID: run.id, at: now, exit: .stopped))
        open[id] = nil
      }
    }
    do { try await tracking.save(intervals) } catch { lastWriteFailure = now }
    isEnabled = enabled
    await beat()
    updateHeartbeatTask()
  }

  /// Forgets everything recorded. Agents running now are counted again from this instant, since
  /// they are still running; nothing before it comes back.
  public func clear() async {
    await prepare()
    guard !isSealed else { return }
    let now = clock.now().storageRounded
    let running = liveRuns
    open.removeAll()
    leftovers.removeAll()
    previousHeartbeat = nil
    wroteSuspend = false
    do { try await ledger.clear() } catch { lastWriteFailure = now }
    let intervals = isEnabled ? [UsageTrackingInterval(from: now)] : []
    do { try await tracking.save(intervals) } catch { lastWriteFailure = now }
    guard isEnabled else { return }
    for run in running {
      let restarted = UsageRun(
        sessionID: run.sessionID, providerID: run.providerID, modelID: run.modelID,
        kind: run.kind, afterRelaunch: run.afterRelaunch, afterSwitch: run.afterSwitch,
        startedAt: now)
      open[run.sessionID] = restarted
      await write(.start(restarted))
    }
    await beat()
    updateHeartbeatTask()
  }

  /// The runs open now, as they would read if they ended this instant. Not the ones the
  /// previous launch left, which are waiting to be settled.
  public func openRuns() -> [UsageRun] {
    Array(open.values.filter { !leftovers.contains($0.id) })
  }

  /// The runs this launch is timing.
  private var liveRuns: [UsageRun] {
    open.values.filter { $0.detachedAt == nil && !leftovers.contains($0.id) }
  }

  /// Writes the heartbeat. Called by the timer, and after each change.
  public func beat() async {
    guard !isSealed else { return }
    let live = liveRuns.map(\.id)
    // Until the previous launch's runs are settled, its heartbeat on disk is what dates them.
    guard isSettled || !live.isEmpty else { return }
    let heartbeat =
      live.isEmpty ? nil : UsageHeartbeat(at: clock.now().storageRounded, runIDs: live)
    do { try await ledger.writeHeartbeat(heartbeat) } catch { lastWriteFailure = clock.now() }
  }

  private func updateHeartbeatTask() {
    let needed = !isSealed && !liveRuns.isEmpty
    if needed, heartbeatTask == nil {
      let interval = heartbeatInterval
      heartbeatTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: interval)
          guard !Task.isCancelled else { return }
          await self?.beat()
        }
      }
    } else if !needed {
      heartbeatTask?.cancel()
      heartbeatTask = nil
    }
  }

  private func write(_ event: UsageLedgerEvent) async {
    guard !isSealed else { return }
    do {
      try await ledger.append(event)
    } catch {
      lastWriteFailure = clock.now()
    }
  }
}
