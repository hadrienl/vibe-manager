import VibeDomain

/// A session that was closed, and what happened to the process it was attached to.
public struct SessionClosure: Equatable, Sendable {
  public let session: WorkSession
  public let detachment: SessionDetachOutcome

  public init(session: WorkSession, detachment: SessionDetachOutcome) {
    self.session = session
    self.detachment = detachment
  }
}

/// Stops a session's process and records that it is closed, without losing anything else.
///
/// The order is the whole point: the process is stopped **before** the new status is written. A
/// session written closed while its agent is still running would, if the application stopped
/// between the two, come back as a closed session with a live process nobody owns.
///
/// The pane is deliberately left in place. Reading what the agent said last is precisely what
/// "keep it in the history" means; only archiving releases it.
public struct CloseSession: Sendable {
  private let repository: any SessionRepository
  private let runtime: any SessionRuntime
  private let clock: any SessionClock

  public init(
    repository: any SessionRepository,
    runtime: any SessionRuntime = DetachedSessionRuntime(),
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.repository = repository
    self.runtime = runtime
    self.clock = clock
  }

  @discardableResult
  public func callAsFunction(id: SessionID) async throws -> SessionClosure {
    guard try await repository.session(id: id) != nil else {
      throw ChangeSessionStatusError.sessionNotFound(id)
    }

    let detachment = await runtime.detach(id)
    let now = clock.now()

    // The status is decided on a read taken *after* the stop, never on the one taken before it.
    // Stopping a terminal suspends for as long as the grace period, and an agent that exits of
    // its own accord in that window has already written `closed`: closing it a second time from
    // a stale copy throws an invalid transition, which the caller would have no way to act on.
    let updated = try await repository.mutate(id: id) { session in
      guard session.status == .active else { return }
      try session.close(at: max(now, session.updatedAt))
    }

    guard let updated else { throw ChangeSessionStatusError.sessionNotFound(id) }
    return SessionClosure(session: updated, detachment: detachment)
  }
}
