import Foundation
import VibeDomain

/// Keeps the runtime document up to date for the instance that owns it.
///
/// One writer, on purpose. The document says which sessions this copy of the application is
/// running, and two writers would each hold half of that truth; every path that changes it —
/// launch, stop, quit, and the claim taken at startup — goes through here.
public actor SessionRuntimeRecorder {
  private let store: any SessionRuntimeStateStore
  private let probe: any ProcessLivenessProbe
  private let clock: any SessionClock
  private let processIdentifier: Int32
  private var state: SessionRuntimeState
  /// Set once another copy of the application has been found holding the document.
  ///
  /// From then on this instance writes nothing: the document belongs to the copy that is working
  /// in those sessions, and a first launch here would otherwise overwrite its pid and its process
  /// groups at the first session started — leaving its agents unfindable at its own next launch.
  private var isSealed = false

  public init(
    store: any SessionRuntimeStateStore,
    processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
    probe: any ProcessLivenessProbe = SystemProcessLivenessProbe(),
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.store = store
    self.processIdentifier = processIdentifier
    self.probe = probe
    self.clock = clock
    let now = clock.now()
    state = SessionRuntimeState(
      phase: .running,
      processIdentifier: processIdentifier,
      processStartedAt: probe.startTime(of: processIdentifier),
      launchedAt: now,
      updatedAt: now
    )
  }

  /// Gives up writing: the document is another instance's, and this one only reads from now on.
  public func seal() {
    isSealed = true
  }

  /// Whether this instance has given up writing. Quitting reads it to know that the sessions the
  /// store calls active are not its own to close.
  public func isReadOnly() -> Bool {
    isSealed
  }

  /// What the previous instance left behind, read without touching it.
  public func peek() async -> SessionRuntimeState? {
    await store.read()
  }

  /// Takes the document over for this instance, and answers what it held.
  ///
  /// This is what makes "restarted exactly once" true: the intention is consumed here, before
  /// the first session is restarted, so an application that dies in the middle of a restoration
  /// does not replay it at the next launch. What was not restarted is left as closed sessions,
  /// which Restart puts back to work one gesture at a time.
  @discardableResult
  public func claim() async -> SessionRuntimeState? {
    let previous = await store.read()
    let now = clock.now()
    state = SessionRuntimeState(
      phase: .running,
      processIdentifier: processIdentifier,
      processStartedAt: probe.startTime(of: processIdentifier),
      launchedAt: now,
      updatedAt: now
    )
    await store.write(state)
    return previous
  }

  /// Records a session's process, with the instant the kernel says it started.
  ///
  /// The start time is asked of the system rather than taken from the clock: it is the only half
  /// of the pair that can tell a leftover from a recycled pid, and a value we made up ourselves
  /// would agree with nothing.
  public func started(_ id: SessionID, processGroup: Int32?) async {
    let startedAt = processGroup.flatMap { probe.startTime(of: $0) }
    var records = state.sessions.filter { $0.sessionID != id }
    records.append(
      SessionRuntimeRecord(
        sessionID: id,
        processGroup: processGroup,
        processStartedAt: startedAt
      )
    )
    await update(sessions: records)
  }

  public func stopped(_ id: SessionID) async {
    let records = state.sessions.filter { $0.sessionID != id }
    guard records.count != state.sessions.count else { return }
    await update(sessions: records)
  }

  public func records() -> [SessionRuntimeRecord] {
    state.sessions
  }

  /// Writes the intention to resume, and says this instance stopped on purpose.
  ///
  /// The groups are dropped: those processes have just been stopped, and a group recorded here
  /// would be looked for — and possibly signalled — at the next launch.
  public func markStopped(resuming ids: [SessionID]) async {
    guard !isSealed else { return }
    let now = clock.now()
    state.phase = .stopped
    state.stoppedAt = now.storageRounded
    state.updatedAt = now.storageRounded
    state.sessions = ids.map { SessionRuntimeRecord(sessionID: $0) }
    state.resuming = nil
    state.host = nil
    await store.write(state)
  }

  /// Says this instance quit and left `kept` running in the terminal host.
  ///
  /// Their process groups are kept, unlike on a plain quit: if the host is gone at the next
  /// launch, those groups are what is looked for — and, identified, stopped — before anything is
  /// resumed in their place.
  public func markDetached(
    keeping kept: [SessionID],
    resuming closed: [SessionID],
    host: TerminalHostIdentity?
  ) async {
    guard !isSealed else { return }
    let now = clock.now()
    let recorded = Dictionary(
      state.sessions.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
    state.phase = .detached
    state.stoppedAt = now.storageRounded
    state.updatedAt = now.storageRounded
    state.sessions = kept.map { recorded[$0] ?? SessionRuntimeRecord(sessionID: $0) }
    state.resuming = closed.map { SessionRuntimeRecord(sessionID: $0) }
    state.host = host
    await store.write(state)
  }

  private func update(sessions: [SessionRuntimeRecord]) async {
    state.sessions = sessions
    guard !isSealed else { return }
    state.updatedAt = clock.now().storageRounded
    await store.write(state)
  }
}
