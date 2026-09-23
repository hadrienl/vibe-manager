/// Whether closing a session whose agent is still running asks first.
///
/// Read synchronously, at the moment ⌘W is pressed: the answer decides whether a dialog opens or
/// the agent stops, and it cannot wait on a suspension point to be known.
@MainActor
public protocol SessionClosePreferences: AnyObject {
  var confirmsStoppingRunningAgent: Bool { get set }
}

/// Kept for this run only. What a workspace assembled without the system around it uses.
@MainActor
public final class InMemorySessionClosePreferences: SessionClosePreferences {
  public var confirmsStoppingRunningAgent: Bool

  public init(confirmsStoppingRunningAgent: Bool = true) {
    self.confirmsStoppingRunningAgent = confirmsStoppingRunningAgent
  }
}
