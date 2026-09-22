import Foundation
import VibeDomain

/// What quitting did to the sessions that were running.
public struct SessionShutdown: Equatable, Sendable {
  /// The sessions this shutdown closed, in the order they were closed — which is the order they
  /// will be resumed in.
  public let closed: [WorkSession]
  public let detachments: [SessionID: SessionDetachOutcome]

  public init(closed: [WorkSession], detachments: [SessionID: SessionDetachOutcome]) {
    self.closed = closed
    self.detachments = detachments
  }

  public var unreachable: [SessionID] {
    detachments.filter { $0.value.isUnreachable }.map(\.key)
  }
}

/// Stops what is running, closes it in the store, and leaves behind the intention to resume it.
///
/// The order is the one `CloseSession` set and it does not change here: the process is stopped
/// **before** the status is written. A session written closed while its agent is still running
/// becomes, if the application dies between the two, a closed session with a process nobody owns.
///
/// The intention is written **after** those closures, so it can only name sessions that were
/// really closed: written first, a quit interrupted halfway would leave an intention to resume
/// sessions the store still calls active, and the two roads to a restart would walk over each
/// other at the next launch.
///
/// The stops are paid concurrently, for the same reason `PTYTerminalSupervisor.stopAll` does: each
/// one waits out a grace period, and a quit that paid them one after another would take as many
/// seconds as there are agents — past the deadline the application gives itself, the reply leaves
/// without this work having finished, and a deliberate quit would be read as a crash at the next
/// launch. The closures still come after every stop, and still in the order the sessions will be
/// resumed in.
public struct PrepareForQuit: Sendable {
  private let repository: any SessionRepository
  private let runtime: any SessionRuntime
  private let recorder: SessionRuntimeRecorder
  private let clock: any SessionClock

  public init(
    repository: any SessionRepository,
    runtime: any SessionRuntime,
    recorder: SessionRuntimeRecorder,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.repository = repository
    self.runtime = runtime
    self.recorder = recorder
    self.clock = clock
  }

  @discardableResult
  public func callAsFunction() async -> SessionShutdown {
    let ids = await candidates()
    // Stopped first, always — including for a session the store turns out not to hold any more:
    // the process is ours whatever the document says.
    let detachments = await detachAll(ids)
    var closed: [WorkSession] = []

    for id in ids {
      let now = clock.now()
      // The status is decided on a read taken after the stop. Stopping a terminal waits out a
      // grace period, and an agent that exits of its own accord in that window has already
      // written its own `closed`; closing it again from a stale copy would throw.
      let updated = try? await repository.mutate(id: id) { session in
        guard session.status == .active else { return }
        try session.close(at: max(now, session.updatedAt))
      }
      guard let session = updated, session.status == .closed else { continue }
      closed.append(session)
    }

    await recorder.markStopped(resuming: closed.map(\.id))
    return SessionShutdown(closed: closed, detachments: detachments)
  }

  private func detachAll(_ ids: [SessionID]) async -> [SessionID: SessionDetachOutcome] {
    await withTaskGroup(of: (SessionID, SessionDetachOutcome).self) { group in
      for id in ids {
        group.addTask { (id, await runtime.detach(id)) }
      }
      var outcomes: [SessionID: SessionDetachOutcome] = [:]
      for await (id, outcome) in group {
        outcomes[id] = outcome
      }
      return outcomes
    }
  }

  /// Everything that might have a process behind it: what the store calls active, and what this
  /// instance recorded as running.
  ///
  /// The two are asked for together because neither is enough on its own. A store that cannot be
  /// read would otherwise take the whole intention down with it, and a session the launcher
  /// started but the store never heard about would be left running.
  private func candidates() async -> [SessionID] {
    // A copy that found the document held by another instance closes only what it started
    // itself. The sessions the store calls active are the other copy's, running under its own
    // agents, and closing them here would be a status written about somebody else's process.
    guard await !recorder.isReadOnly() else {
      return await recorder.records().map(\.sessionID)
    }

    let stored = (try? await repository.sessions()) ?? []
    // Most recently worked first, and stated here rather than inherited from the store's own
    // order: this is the order the sessions are closed in, and therefore the order the next
    // launch will bring them back in. The one the user was in must not come back last.
    var ids =
      stored
      .filter { $0.status == .active }
      .sorted {
        $0.updatedAt == $1.updatedAt
          ? $0.id.description < $1.id.description : $0.updatedAt > $1.updatedAt
      }
      .map(\.id)
    let known = Set(ids)
    for record in await recorder.records() where !known.contains(record.sessionID) {
      ids.append(record.sessionID)
    }
    return ids
  }
}
