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
  private let changeStatus: ChangeSessionStatus

  public init(
    repository: any SessionRepository,
    runtime: any SessionRuntime = DetachedSessionRuntime(),
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.repository = repository
    self.runtime = runtime
    changeStatus = ChangeSessionStatus(repository: repository, clock: clock)
  }

  @discardableResult
  public func callAsFunction(id: SessionID) async throws -> SessionClosure {
    guard let current = try await repository.session(id: id) else {
      throw ChangeSessionStatusError.sessionNotFound(id)
    }

    let detachment = await runtime.detach(id)

    // Closing something already closed is not a failure: a session whose agent exited on its own
    // is closed before the user ever presses the command, and the command must still work.
    guard current.status == .active else {
      return SessionClosure(session: current, detachment: detachment)
    }

    let closed = try await changeStatus(id: id, action: .close)
    return SessionClosure(session: closed, detachment: detachment)
  }
}
