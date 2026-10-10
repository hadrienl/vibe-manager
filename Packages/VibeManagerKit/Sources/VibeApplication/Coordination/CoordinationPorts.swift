import Foundation
import VibeDomain

/// The user's settings for coordination (#352).
@MainActor
public protocol CoordinationPreferences: AnyObject {
  /// How many children of one coordinator may run at once.
  var maximumRunningChildren: Int { get set }
}

public enum CoordinationLimits {
  public static let defaultRunningChildren = 3
  public static let runningChildren = 1...10
}

/// One thing a coordinator did to a child, kept with the child so that who did what can be read
/// (#352).
public struct CoordinationTraceEntry: Hashable, Codable, Sendable {
  public enum Action: Hashable, Codable, Sendable {
    case created
    case messaged
    case movedTo(SessionTaskStatus)
    case started
    case closed
  }

  public let date: Date
  public let coordinatorName: String
  public let action: Action
  /// What was sent, cut short.
  public let detail: String?

  public init(date: Date, coordinatorName: String, action: Action, detail: String? = nil) {
    self.date = date
    self.coordinatorName = coordinatorName
    self.action = action
    self.detail = detail
  }

  /// The longest a message is kept in the trace.
  public static let detailLimit = 200
}

/// A wake-up a coordinator asked for (#352).
public struct CoordinationWake: Hashable, Codable, Sendable {
  public let date: Date
  public let reason: String

  public init(date: Date, reason: String) {
    self.date = date
    self.reason = reason
  }
}

/// Where the traces and the wake-ups are kept, beside the store (#352).
public protocol CoordinationStore: Sendable {
  func trace(of child: SessionID) async -> [CoordinationTraceEntry]
  func append(_ entry: CoordinationTraceEntry, to child: SessionID) async
  func wakes() async -> [SessionID: CoordinationWake]
  func setWake(_ wake: CoordinationWake?, for coordinator: SessionID) async
}
