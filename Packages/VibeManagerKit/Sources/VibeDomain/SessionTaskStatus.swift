import Foundation

/// Where the user is with a session, as a task: what they plan to do, do, wait on, or have done.
///
/// A second axis beside `SessionStatus`, never a renaming of it. `SessionStatus` says what the
/// process does — an agent runs or it does not — and this says where the work stands. A session
/// can wait on a review with its agent still running, or be in progress with its agent stopped.
/// Only `archived` ties the two together: a session is archived as a task exactly when it is
/// archived as a process, and `WorkSession` is what keeps that true (#80).
public enum SessionTaskStatus: String, Codable, CaseIterable, Sendable {
  case todo
  case doing
  case waiting
  case done
  case archived

  /// The four columns of the sidebar, in order. Archived is not one: it has a quieter way in.
  public static let columns: [SessionTaskStatus] = [.todo, .doing, .waiting, .done]

  /// The statuses before this one, nearest first: what a swipe to the right offers.
  public var previous: [SessionTaskStatus] {
    guard let index = Self.columns.firstIndex(of: self) else { return [] }
    return Self.columns[..<index].reversed()
  }

  /// The statuses after this one, nearest first: what a swipe to the left offers.
  ///
  /// Archiving is only offered from Done. It stops the agent and takes the session out of every
  /// column, which is the end of a task, not a step any other status is one gesture away from.
  public var next: [SessionTaskStatus] {
    guard let index = Self.columns.firstIndex(of: self) else { return [] }
    guard self != .done else { return [.archived] }
    return Array(Self.columns[(index + 1)...])
  }

  /// What a session stored before this status existed is, read from its lifecycle.
  ///
  /// A running agent is work in progress, and one that was created and never started is work
  /// still to do. A session whose agent ran and stopped is taken as finished: the old Closed tab
  /// held exactly those.
  public static func inferred(from status: SessionStatus, hasEverStarted: Bool)
    -> SessionTaskStatus
  {
    switch status {
    case .active: return .doing
    case .closed: return hasEverStarted ? .done : .todo
    case .archived: return .archived
    }
  }
}

public enum SessionTaskStatusError: Error, Equatable, Sendable {
  /// Archiving and unarchiving stop or release a process, so they go through the lifecycle
  /// rather than through a status change.
  case requiresLifecycleChange(from: SessionTaskStatus, to: SessionTaskStatus)
}
