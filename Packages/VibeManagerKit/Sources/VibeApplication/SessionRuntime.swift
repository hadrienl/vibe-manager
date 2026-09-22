import VibeDomain

/// What became of the process a session was attached to.
///
/// `unreachable` is not a detail to swallow: the terminal escalates to `SIGKILL` and, when the
/// process group still cannot be reaped, releases its descriptors anyway. The application has
/// then let go of everything it held, but the group may well be alive — and saying so is the
/// only honest way to claim that nothing stays attached to an archived session.
public enum SessionDetachOutcome: Equatable, Sendable {
  case wasNotRunning
  case stopped
  case unreachable(processIdentifier: Int32)

  public var isUnreachable: Bool {
    if case .unreachable = self { return true }
    return false
  }
}

/// What the interface can do to a session that is alive, described from the application layer.
///
/// The panes, the agent observers and the output readers all live in the interface, so only it
/// can guarantee that nothing is left of a session. Naming that as a port is what lets the
/// closing and archiving use cases be tested without a terminal, a process or a view.
public protocol SessionRuntime: Sendable {
  /// Stops the terminal and ends the agent observation. Idempotent: a session that was never
  /// started, or that has already been detached, answers `wasNotRunning` rather than failing.
  func detach(_ id: SessionID) async -> SessionDetachOutcome

  /// Releases the pane itself, and with it the terminal's replay buffer. Only archiving does
  /// this: a closed session keeps its pane so its last output stays readable.
  func dispose(_ id: SessionID) async
}

/// A runtime for a workspace that has none — tests, and an application model built without a
/// launcher. Nothing is running, so there is nothing to stop.
public struct DetachedSessionRuntime: SessionRuntime {
  public init() {}

  public func detach(_ id: SessionID) async -> SessionDetachOutcome { .wasNotRunning }

  public func dispose(_ id: SessionID) async {}
}
