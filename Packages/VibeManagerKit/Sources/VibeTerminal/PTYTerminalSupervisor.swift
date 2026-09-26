import Foundation
import VibeApplication
import VibeDomain

public actor PTYTerminalSupervisor: TerminalSupervisor {
  private var sessions: [SessionID: PTYTerminalSession] = [:]

  public init() {}

  public func start(_ spec: TerminalSpec, for id: SessionID) async throws -> any TerminalSession {
    if let existing = sessions[id] {
      guard await existing.state().isFinished else {
        throw TerminalError.sessionAlreadyRunning(id)
      }
      sessions[id] = nil
    }

    let session = try PTYTerminalSession.start(id: id, spec: spec)
    sessions[id] = session
    Task { await self.releaseWhenFinished(session) }
    return session
  }

  /// Terminals running here. A session is forgotten as soon as it has ended.
  public func runningCount() -> Int {
    sessions.count
  }

  public func session(for id: SessionID) -> (any TerminalSession)? {
    sessions[id]
  }

  public func stop(id: SessionID, gracePeriod: Duration) async {
    guard let session = sessions[id] else { return }
    await session.stop(gracePeriod: gracePeriod)
    // The grace period is long enough for a replacement session to have been registered under the
    // same identifier; only the session this call stopped may be evicted.
    guard sessions[id] === session else { return }
    sessions[id] = nil
  }

  public func stopAll(gracePeriod: Duration) async {
    let running = sessions.values
    sessions.removeAll()

    // Sessions are stopped concurrently: a grace period paid one session at a time would delay
    // application termination by the number of open terminals.
    await withTaskGroup(of: Void.self) { group in
      for session in running {
        group.addTask {
          await session.stop(gracePeriod: gracePeriod)
        }
      }
    }
  }

  private func releaseWhenFinished(_ session: PTYTerminalSession) async {
    let attachment = await session.attach()
    for await _ in attachment.events {}
    guard sessions[session.id] === session else { return }
    sessions[session.id] = nil
  }
}
