import VibeDomain

/// A session that was archived, and what happened to the process it was attached to.
public struct SessionArchival: Equatable, Sendable {
  public let session: WorkSession
  public let detachment: SessionDetachOutcome

  public init(session: WorkSession, detachment: SessionDetachOutcome) {
    self.session = session
    self.detachment = detachment
  }
}

/// Takes a session out of the current views without taking anything away from it.
///
/// Archiving only ever writes `lifecycle`. Notes, repositories and their Git snapshots, the
/// template, the initial prompt, the appearance and the agent's resume identifier all cross the
/// archive and come back untouched — that is what makes the operation safe to offer behind a
/// single confirmation.
///
/// A running session is archived through its closure rather than in one jump: the domain only
/// allows `archive` from `closed`, so the store always records a real `closedAt` before an
/// `archivedAt`, and the order of events stays readable long after the fact.
public struct ArchiveSession: Sendable {
  private let repository: any SessionRepository
  private let runtime: any SessionRuntime
  private let close: CloseSession
  private let clock: any SessionClock

  public init(
    repository: any SessionRepository,
    runtime: any SessionRuntime = DetachedSessionRuntime(),
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.repository = repository
    self.runtime = runtime
    self.clock = clock
    close = CloseSession(repository: repository, runtime: runtime, clock: clock)
  }

  @discardableResult
  public func callAsFunction(id: SessionID) async throws -> SessionArchival {
    // Stops the process and writes `closed` first, so the archived status is only ever reached
    // from a state where nothing is running.
    let closure = try await close(id: id)
    let now = clock.now()

    // Read again inside the write, for the same reason closing does: the copy `close` handed
    // back was taken before this line, and the store is the only thing that knows the truth now.
    let updated = try await repository.mutate(id: id) { session in
      guard session.status == .closed else { return }
      try session.archive(at: max(now, session.updatedAt))
    }

    // The pane goes last, once the store agrees the session is archived: releasing it earlier
    // would throw away the terminal's history for an archive that might still have failed.
    await runtime.dispose(id)

    guard let updated else { throw ChangeSessionStatusError.sessionNotFound(id) }
    return SessionArchival(session: updated, detachment: closure.detachment)
  }
}

/// Brings an archived session back among the current ones, and starts nothing.
///
/// Restoring returns a session to `closed`, which is exactly the state #10's Restart works from.
/// Relaunching an agent as a side effect of unarchiving would decide for the user, in a view
/// where they are looking for something rather than asking for it to run.
public struct RestoreSession: Sendable {
  private let repository: any SessionRepository
  private let changeStatus: ChangeSessionStatus

  public init(
    repository: any SessionRepository,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.repository = repository
    changeStatus = ChangeSessionStatus(repository: repository, clock: clock)
  }

  @discardableResult
  public func callAsFunction(id: SessionID) async throws -> WorkSession {
    guard let current = try await repository.session(id: id) else {
      throw ChangeSessionStatusError.sessionNotFound(id)
    }
    guard current.status == .archived else { return current }
    return try await changeStatus(id: id, action: .restore)
  }
}
