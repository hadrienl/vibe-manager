import Foundation
import VibeDomain

/// What quitting with the agents left running did.
public struct SessionDetachment: Equatable, Sendable {
  /// Sessions left running in the terminal host, still `active` in the store.
  public let kept: [SessionID]
  /// What had to be stopped anyway, because its process would have died with the application.
  public let shutdown: SessionShutdown

  public init(kept: [SessionID], shutdown: SessionShutdown) {
    self.kept = kept
    self.shutdown = shutdown
  }
}

/// Quits and leaves the agents working: the other answer to the question `PrepareForQuit` answers.
///
/// Nothing is written to the store for a session that is left running, because it *is* active:
/// the whole point of ADR 0017 is that the store may now say so of a process the application no
/// longer holds. A session whose process lives in the application itself — the host could not be
/// started for it — cannot be left, and goes the way of a plain quit: stopped, closed, and named
/// in the intention to resume.
///
/// The order is the one the next launch depends on. The document says `detached` **before** the
/// host is told to keep running: dying between the two leaves a host that stops everything when
/// its client vanishes, and a document whose host is then missing, which reads as the crash it
/// was. The other order would leave agents running under a document that does not mention them.
/// Both come before any stop, which is the one step that can outlast the quit's deadline.
public struct DetachForQuit: Sendable {
  private let prepare: PrepareForQuit
  private let handOff: any SessionHandOff
  private let host: any TerminalHosting
  private let recorder: SessionRuntimeRecorder

  public init(
    repository: any SessionRepository,
    runtime: any SessionRuntime,
    handOff: any SessionHandOff,
    host: any TerminalHosting,
    recorder: SessionRuntimeRecorder,
    clock: any SessionClock = SystemSessionClock()
  ) {
    prepare = PrepareForQuit(
      repository: repository, runtime: runtime, recorder: recorder, clock: clock)
    self.handOff = handOff
    self.host = host
    self.recorder = recorder
  }

  @discardableResult
  public func callAsFunction() async -> SessionDetachment {
    let ids = await prepare.candidates()
    var kept: [SessionID] = []
    // A copy that only reads the document has no business leaving anything behind in it: the
    // host is the other copy's, and so are the sessions the store calls active.
    if await !recorder.isReadOnly() {
      for id in ids where await handOff.handOff(id) {
        kept.append(id)
      }
    }
    let others = ids.filter { !kept.contains($0) }
    guard !kept.isEmpty else {
      let shutdown = await prepare.stopAndClose(others)
      await recorder.markStopped(resuming: shutdown.closed.map(\.id))
      await host.relinquish(keepRunning: false)
      return SessionDetachment(kept: [], shutdown: shutdown)
    }

    // The host is told before anything that can take time: stopping what could not be left pays
    // a grace period, and the application quits on a deadline whether or not it has finished. A
    // goodbye that never left would read, to the host, as a crash — and stop the very agents the
    // user asked to keep. What will be stopped is written as the intention to resume first, and
    // narrowed to what really closed once it has.
    let identity = await host.hostIdentity()
    await recorder.markDetached(keeping: kept, resuming: others, host: identity)
    await host.relinquish(keepRunning: true)
    let shutdown = await prepare.stopAndClose(others)
    await recorder.markDetached(
      keeping: kept, resuming: shutdown.closed.map(\.id), host: identity)
    return SessionDetachment(kept: kept, shutdown: shutdown)
  }
}
