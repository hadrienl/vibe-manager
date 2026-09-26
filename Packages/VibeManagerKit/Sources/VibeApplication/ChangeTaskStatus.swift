import Foundation
import VibeDomain

/// Moves a session between the columns of the sidebar (#80).
///
/// It writes the status and nothing else: no process is started or stopped here. Archiving goes
/// through `ArchiveSession` and unarchiving through `RestoreSession`, which stop and release what
/// they must before they write; the domain refuses those two moves from this path.
public struct ChangeTaskStatus: Sendable {
  private let repository: any SessionRepository
  private let clock: any SessionClock

  public init(
    repository: any SessionRepository,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.repository = repository
    self.clock = clock
  }

  @discardableResult
  public func callAsFunction(id: SessionID, to status: SessionTaskStatus) async throws
    -> WorkSession
  {
    let now = clock.now()
    let updated = try await repository.mutate(id: id) { session in
      // Clamped like every other transition: a wall clock that stepped back must not strand the
      // user, and `updatedAt` stays monotonic.
      try session.setTaskStatus(status, at: max(now, session.updatedAt))
    }
    guard let updated else { throw ChangeSessionStatusError.sessionNotFound(id) }
    return updated
  }

  /// Puts a session the user just started or restarted back in progress.
  ///
  /// Only from To Do and Done: starting a planned task is beginning it, and restarting a finished
  /// one is reopening it. A session waiting on something stays where the user put it — its agent
  /// running again does not mean the review it waits for has come in.
  @discardableResult
  public func beginWork(id: SessionID) async throws -> WorkSession? {
    guard let current = try await repository.session(id: id) else { return nil }
    guard current.taskStatus == .todo || current.taskStatus == .done else { return current }
    return try await self(id: id, to: .doing)
  }
}

/// A status is a word of the source, and says nothing the user typed.
extension SessionTaskStatus: DiagnosticTokenConvertible {}
