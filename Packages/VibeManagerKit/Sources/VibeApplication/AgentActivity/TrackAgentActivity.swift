import Foundation
import VibeDomain

/// A session's activity changed.
public struct AgentActivityUpdate: Hashable, Sendable {
  public let sessionID: SessionID
  /// `nil` once the session is forgotten.
  public let state: AgentActivityState?
}

/// Follows what the agent of every running session is doing (#45), and remembers what the user
/// has not read yet.
///
/// Fed from four sides — the agent's own log, the terminal's output, the user's keystrokes and
/// what the window shows — and the only place those are put together: the rules themselves are
/// `AgentActivityMachine`'s. #40 and #38 read the same states rather than detecting anything again.
public actor TrackAgentActivity {
  private struct Tracked {
    var state = AgentActivityState()
    var decoder: (any AgentSignalDecoding)?
    var logPosition: AgentActivityLogPosition?
    /// What the previous launch left the agent doing, for a process adopted as it was.
    var restoredActivity: AgentActivity?
    var restoredConfirmation = false
    /// The event that opened the source beyond the hooks, and the task reading it. One at a time:
    /// Claude Code starts a session again on every `/clear` and every compaction.
    var sourceEvent: AgentActivityEvent?
    var sourceTask: Task<Void, Never>?
    var tasks: [Task<Void, Never>] = []
    /// Which process the tasks belong to. A log line still on its way from the previous one must
    /// not move the new one.
    var generation = 0
  }

  private let logs: any AgentActivityLogStore
  private let store: any AgentActivityStateStore
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async throws -> Void
  private let persistenceDelay: Duration

  private var sessions: [SessionID: Tracked] = [:]
  /// The session in front of the user. What happens to it is seen as it happens — replayed after
  /// an adoption included: it is on screen now.
  private var visibleSessionID: SessionID?
  private var continuations: [UUID: AsyncStream<AgentActivityUpdate>.Continuation] = [:]
  private var timer: Task<Void, Never>?
  private var pendingWrite: Task<Void, Never>?
  private var hasLoaded = false

  public init(
    logs: any AgentActivityLogStore,
    store: any AgentActivityStateStore,
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    persistenceDelay: Duration = .seconds(1)
  ) {
    self.logs = logs
    self.store = store
    self.now = now
    self.sleep = sleep
    self.persistenceDelay = persistenceDelay
  }

  /// Every change from now on, for as long as the stream is kept.
  public func updates() -> AsyncStream<AgentActivityUpdate> {
    let (stream, continuation) = AsyncStream<AgentActivityUpdate>.makeStream()
    let key = UUID()
    continuations[key] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeContinuation(key) }
    }
    return stream
  }

  private func removeContinuation(_ key: UUID) {
    continuations[key] = nil
  }

  public func state(for id: SessionID) -> AgentActivityState? {
    sessions[id]?.state
  }

  public func states() -> [SessionID: AgentActivityState] {
    sessions.mapValues(\.state)
  }

  /// The event that named the session's transcript — Claude Code's `SessionStart` — for the
  /// conversation view to read the same file (#38). `nil` until the agent's hooks reported one.
  public func sourceEvent(for id: SessionID) -> AgentActivityEvent? {
    sessions[id]?.sourceEvent
  }

  /// Reads back what the previous launch left: the unread marks, and how far each log was read.
  /// Nothing is running yet, so every session starts idle until its process is started or adopted.
  public func load() async {
    guard !hasLoaded else { return }
    hasLoaded = true
    for (id, persisted) in await store.read() where sessions[id] == nil {
      var tracked = Tracked()
      tracked.state = AgentActivityState(unreadSince: persisted.unreadSince)
      tracked.logPosition = persisted.log
      tracked.restoredActivity = persisted.activity
      tracked.restoredConfirmation = persisted.isConfirmed
      tracked.sourceEvent = persisted.sourceEvent?.event
      sessions[id] = tracked
      publish(id)
    }
  }

  // MARK: - Processes

  /// The log a new process of this session will report to, emptied first.
  public func prepareLog(for id: SessionID) async throws -> URL {
    try await logs.prepareLog(for: id)
  }

  /// A process started for the session. `decoder` is `nil` for an agent launched without hooks,
  /// whose session then has no log: one left by an earlier process would be read as this one's.
  public func processStarted(_ id: SessionID, decoder: (any AgentSignalDecoding)?) async {
    if decoder == nil { await logs.removeLog(for: id) }
    var tracked = sessions[id] ?? Tracked()
    cancelTasks(of: &tracked)
    let previous = tracked.state
    tracked.decoder = decoder
    tracked.logPosition = nil
    tracked.restoredActivity = nil
    tracked.restoredConfirmation = false
    tracked.sourceEvent = nil
    tracked.state = reduce(tracked.state, .processStarted(structured: decoder != nil), for: id)
    sessions[id] = tracked
    if decoder != nil { follow(id, from: nil) }
    changed(id, from: previous, force: true)
  }

  /// A process the terminal host kept while the application was closed is back. What it did in
  /// the meantime is read from where the last launch stopped, as having happened unseen.
  public func processAdopted(_ id: SessionID, decoder: (any AgentSignalDecoding)?) async {
    await load()
    // A process launched without hooks has no log, and one launched with them always has one.
    let hasLog = decoder != nil ? await logs.existingLog(for: id) != nil : false
    var tracked = sessions[id] ?? Tracked()
    cancelTasks(of: &tracked)
    let previous = tracked.state
    tracked.decoder = hasLog ? decoder : nil
    // What the hooks left pending is still pending, the process never having stopped — but only
    // hooks that had spoken are believed. Others still have ten seconds to, as at a launch.
    let confirmed = hasLog && tracked.restoredConfirmation
    tracked.state.activity = confirmed ? tracked.restoredActivity ?? .idle : .idle
    tracked.state.source =
      confirmed ? .structured : hasLog ? .unconfirmed(since: now()) : .inferred
    tracked.restoredActivity = nil
    if isVisible(id) { tracked.state.unreadSince = nil }
    sessions[id] = tracked
    if hasLog {
      follow(id, from: tracked.logPosition)
      if let event = tracked.sourceEvent { openSource(after: event, for: id) }
    }
    changed(id, from: previous, force: true)
  }

  public func processEnded(_ id: SessionID) {
    guard var tracked = sessions[id] else { return }
    cancelTasks(of: &tracked)
    let previous = tracked.state
    tracked.state = reduce(tracked.state, .processEnded, for: id)
    tracked.sourceEvent = nil
    sessions[id] = tracked
    changed(id, from: previous)
  }

  /// The session is closed or archived: closing it was its reading.
  public func forget(_ id: SessionID) async {
    guard var tracked = sessions.removeValue(forKey: id) else { return }
    cancelTasks(of: &tracked)
    await logs.removeLog(for: id)
    publish(id, state: nil)
    schedulePersistence()
  }

  // MARK: - Terminal and window

  public func output(_ id: SessionID) {
    guard var tracked = sessions[id], tracked.state.source != .structured else { return }
    let previous = tracked.state
    tracked.state = reduce(tracked.state, .output, for: id)
    sessions[id] = tracked
    changed(id, from: previous)
  }

  public func userInput(_ id: SessionID, _ bytes: [UInt8]) {
    guard var tracked = sessions[id] else { return }
    let previous = tracked.state
    tracked.state = reduce(tracked.state, .userInput(bytes), for: id)
    sessions[id] = tracked
    changed(id, from: previous)
  }

  /// The session now in front of the user, or `nil` when none is: the window is hidden, or
  /// another application is active.
  public func setVisibleSession(_ id: SessionID?) {
    guard id != visibleSessionID else { return }
    visibleSessionID = id
    guard let id, var tracked = sessions[id], tracked.state.unreadSince != nil else { return }
    let previous = tracked.state
    tracked.state.unreadSince = nil
    sessions[id] = tracked
    changed(id, from: previous)
  }

  /// Writes what is pending at once, for the way out.
  public func flush() async {
    pendingWrite?.cancel()
    pendingWrite = nil
    await store.write(persistedStates())
  }

  // MARK: - Log

  private func follow(_ id: SessionID, from position: AgentActivityLogPosition?) {
    guard var tracked = sessions[id] else { return }
    let generation = tracked.generation
    let task = Task { [logs] in
      let events = await logs.events(for: id, from: position)
      for await (event, position) in events {
        guard !Task.isCancelled else { return }
        self.received(event, at: position, for: id, generation: generation)
      }
    }
    tracked.tasks.append(task)
    sessions[id] = tracked
  }

  private func received(
    _ event: AgentActivityEvent,
    at position: AgentActivityLogPosition,
    for id: SessionID,
    generation: Int
  ) {
    guard var tracked = sessions[id], tracked.generation == generation,
      let decoder = tracked.decoder
    else { return }
    let previous = tracked.state
    tracked.logPosition = position
    if let signal = decoder.signal(for: event) {
      tracked.state = reduce(tracked.state, .signal(signal), for: id, at: event.date)
    }
    sessions[id] = tracked
    openSource(after: event, for: id)
    // The position moved: written down even when the state did not.
    changed(id, from: previous, force: true)
  }

  /// Opens what an event names beyond the hooks, in place of what an earlier one had opened.
  private func openSource(after event: AgentActivityEvent, for id: SessionID) {
    guard var tracked = sessions[id], let decoder = tracked.decoder,
      let more = decoder.additionalSignals(after: event)
    else { return }
    let generation = tracked.generation
    tracked.sourceTask?.cancel()
    tracked.sourceEvent = event
    tracked.sourceTask = Task {
      for await signal in more {
        guard !Task.isCancelled else { return }
        self.receivedAdditional(signal, for: id, generation: generation)
      }
    }
    sessions[id] = tracked
  }

  private func receivedAdditional(_ signal: AgentSignal, for id: SessionID, generation: Int) {
    guard var tracked = sessions[id], tracked.generation == generation else { return }
    let previous = tracked.state
    tracked.state = reduce(tracked.state, .signal(signal), for: id)
    sessions[id] = tracked
    changed(id, from: previous)
  }

  // MARK: - Machine

  private func reduce(
    _ state: AgentActivityState,
    _ input: AgentActivityInput,
    for id: SessionID,
    at date: Date? = nil
  ) -> AgentActivityState {
    AgentActivityMachine.reduce(
      state, input,
      context: AgentActivityContext(
        now: date ?? now(),
        isVisible: isVisible(id),
        approvalAnswerKeys: sessions[id]?.decoder?.approvalAnswerKeys ?? []
      ))
  }

  private func isVisible(_ id: SessionID) -> Bool {
    visibleSessionID == id
  }

  private func cancelTasks(of tracked: inout Tracked) {
    for task in tracked.tasks { task.cancel() }
    tracked.tasks = []
    tracked.sourceTask?.cancel()
    tracked.sourceTask = nil
    tracked.generation += 1
  }

  /// Said to the interface, and written down, only when what is shown changes: a keystroke, or a
  /// line of output, moves the instants the fallback counts from and nothing a row displays.
  /// `force` is for what must be written even so — a log position, a new process.
  private func changed(_ id: SessionID, from previous: AgentActivityState, force: Bool = false) {
    guard let current = sessions[id]?.state else { return }
    if AgentActivityMachine.nextDeadline(of: current)
      != AgentActivityMachine.nextDeadline(of: previous)
    {
      scheduleTick()
    }
    guard force || !current.showsTheSame(as: previous) else { return }
    if !current.showsTheSame(as: previous) { publish(id) }
    schedulePersistence()
  }

  private func publish(_ id: SessionID) {
    publish(id, state: sessions[id]?.state)
  }

  private func publish(_ id: SessionID, state: AgentActivityState?) {
    let update = AgentActivityUpdate(sessionID: id, state: state)
    for continuation in continuations.values { continuation.yield(update) }
  }

  // MARK: - Time

  /// One timer for every session, armed only while one of them waits on a deadline.
  private func scheduleTick() {
    timer?.cancel()
    let deadlines = sessions.values.compactMap { AgentActivityMachine.nextDeadline(of: $0.state) }
    guard let deadline = deadlines.min() else {
      timer = nil
      return
    }
    let delay = max(0, deadline.timeIntervalSince(now()))
    timer = Task { [sleep] in
      do {
        try await sleep(.milliseconds(Int((delay * 1000).rounded(.up))))
      } catch {
        return
      }
      self.tick()
    }
  }

  /// Checks every deadline. Called by the timer, and by a test that moved its clock.
  public func tick() {
    for id in sessions.keys {
      guard var tracked = sessions[id] else { continue }
      let next = reduce(tracked.state, .tick, for: id)
      guard !next.showsTheSame(as: tracked.state) else { continue }
      tracked.state = next
      sessions[id] = tracked
      publish(id)
    }
    scheduleTick()
    schedulePersistence()
  }

  // MARK: - Persistence

  private func schedulePersistence() {
    guard pendingWrite == nil else { return }
    pendingWrite = Task { [sleep, persistenceDelay] in
      do {
        try await sleep(persistenceDelay)
      } catch {
        return
      }
      await self.writePending()
    }
  }

  private func writePending() async {
    pendingWrite = nil
    await store.write(persistedStates())
  }

  private func persistedStates() -> [SessionID: PersistedAgentActivity] {
    var result: [SessionID: PersistedAgentActivity] = [:]
    for (id, tracked) in sessions where tracked.state.isWorthKeeping || tracked.logPosition != nil {
      result[id] = PersistedAgentActivity(
        activity: tracked.state.activity,
        unreadSince: tracked.state.unreadSince,
        log: tracked.logPosition,
        isConfirmed: tracked.state.source == .structured,
        sourceEvent: tracked.sourceEvent.map(PersistedAgentActivityEvent.init)
      )
    }
    return result
  }
}
