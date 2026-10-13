/// Whether closing a session whose agent is still running asks first.
///
/// Read synchronously, at the moment ⇧⌘W is pressed: the answer decides whether a dialog opens or
/// the agent stops, and it cannot wait on a suspension point to be known.
@MainActor
public protocol SessionClosePreferences: AnyObject {
  var confirmsStoppingRunningAgent: Bool { get set }
  /// What moving a session whose agent runs to To Do or Waiting does to it (#353).
  var setAsideClose: SetAsideClose { get set }
}

/// What moving a session whose agent runs to To Do or Waiting does to it (#353): the question,
/// or the answer the user asked to keep.
public enum SetAsideClose: String, Sendable, CaseIterable {
  case ask
  case close
  case keepOpen
}

/// Kept for this run only. What a workspace assembled without the system around it uses.
@MainActor
public final class InMemorySessionClosePreferences: SessionClosePreferences {
  public var confirmsStoppingRunningAgent: Bool
  public var setAsideClose: SetAsideClose

  public init(confirmsStoppingRunningAgent: Bool = true, setAsideClose: SetAsideClose = .ask) {
    self.confirmsStoppingRunningAgent = confirmsStoppingRunningAgent
    self.setAsideClose = setAsideClose
  }
}
