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
  private var visibleSessionID: SessionID?
  /// When the visible session became visible. An event older than that happened while nobody was
  /// looking — the application was closed, or another session was in front.
  private var visibleSince: Date?
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
    tracked.decoder = decoder
    tracked.logPosition = nil
    tracked.restoredActivity = nil
    tracked.state = reduce(tracked.state, .processStarted(structured: decoder != nil), for: id)
    sessions[id] = tracked
    if decoder != nil { follow(id, from: nil) }
    changed(id)
  }

  /// A process the terminal host kept while the application was closed is back. What it did in
  /// the meantime is read from where the last launch stopped, as having happened unseen.
  public func processAdopted(_ id: SessionID, decoder: (any AgentSignalDecoding)?) async {
    await load()
    // A process launched without hooks has no log, and one launched with them always has one.
    let hasLog = decoder != nil ? await logs.existingLog(for: id) != nil : false
    var tracked = sessions[id] ?? Tracked()
    cancelTasks(of: &tracked)
    tracked.decoder = hasLog ? decoder : nil
    // What the hooks left pending is still pending: the process never stopped.
    tracked.state.activity = hasLog ? tracked.restoredActivity ?? .idle : .idle
    tracked.restoredActivity = nil
    tracked.state.source = hasLog ? .structured : .inferred
    sessions[id] = tracked
    if hasLog { follow(id, from: tracked.logPosition) }
    changed(id)
  }

  public func processEnded(_ id: SessionID) {
    guard var tracked = sessions[id] else { return }
    cancelTasks(of: &tracked)
    tracked.state = reduce(tracked.state, .processEnded, for: id)
    sessions[id] = tracked
    changed(id)
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
    let next = reduce(tracked.state, .output, for: id)
    guard next != tracked.state else { return }
    tracked.state = next
    sessions[id] = tracked
    changed(id)
  }

  public func userInput(_ id: SessionID, _ bytes: [UInt8]) {
    guard var tracked = sessions[id] else { return }
    let next = reduce(tracked.state, .userInput(bytes), for: id)
    guard next != tracked.state else { return }
    tracked.state = next
    sessions[id] = tracked
    changed(id)
  }

  /// The session now in front of the user, or `nil` when none is: the window is hidden, or
  /// another application is active.
  public func setVisibleSession(_ id: SessionID?) {
    guard id != visibleSessionID else { return }
    visibleSessionID = id
    visibleSince = id == nil ? nil : now()
    guard let id, var tracked = sessions[id], tracked.state.unreadSince != nil else { return }
    tracked.state.unreadSince = nil
    sessions[id] = tracked
    changed(id)
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
    tracked.logPosition = position
    if let signal = decoder.signal(for: event) {
      tracked.state = reduce(tracked.state, .signal(signal), for: id, at: event.date)
    }
    if let more = decoder.additionalSignals(after: event) {
      tracked.tasks.append(
        Task {
          for await signal in more {
            guard !Task.isCancelled else { return }
            self.receivedAdditional(signal, for: id, generation: generation)
          }
        })
    }
    sessions[id] = tracked
    changed(id)
  }

  private func receivedAdditional(_ signal: AgentSignal, for id: SessionID, generation: Int) {
    guard var tracked = sessions[id], tracked.generation == generation else { return }
    tracked.state = reduce(tracked.state, .signal(signal), for: id)
    sessions[id] = tracked
    changed(id)
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
        isVisible: isVisible(id, at: date),
        approvalAnswerKeys: sessions[id]?.decoder?.approvalAnswerKeys ?? []
      ))
  }

  /// Whether the user had this session in front of them when something happened. The log dates
  /// its lines to the second, so a line from the second the session was shown counts as seen.
  private func isVisible(_ id: SessionID, at date: Date?) -> Bool {
    guard visibleSessionID == id, let visibleSince else { return false }
    guard let date else { return true }
    return date >= visibleSince.addingTimeInterval(-1)
  }

  private func cancelTasks(of tracked: inout Tracked) {
    for task in tracked.tasks { task.cancel() }
    tracked.tasks = []
    tracked.generation += 1
  }

  private func changed(_ id: SessionID) {
    publish(id)
    scheduleTick()
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
      guard next != tracked.state else { continue }
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
        log: tracked.logPosition
      )
    }
    return result
  }
}
