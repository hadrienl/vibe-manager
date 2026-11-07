import Foundation

/// Why a message cannot be typed into a session now (#464): told to its coordinator rather than a
/// bare "busy", and logged.
public enum TypingBlock: String, Hashable, Sendable {
  case notRunning
  case working
  case awaitingUser
  case recentKeyboard
  case panel
  case promptText

  /// Why the message waits, for the coordinator's agent.
  public var reason: String {
    switch self {
    case .notRunning: "its agent is not running"
    case .working: "it is busy with a turn"
    case .awaitingUser: "it is waiting for the user"
    case .recentKeyboard: "the user is typing in it"
    case .panel: "a panel is open in its terminal"
    case .promptText: "its prompt holds text the user left there"
    }
  }

  /// Whether only the user can clear it: worth calling them when it lasts.
  public var needsUser: Bool { self == .panel || self == .promptText }
}

/// What waits in a child's outbox, and since when nothing of it was typed (#464).
public struct OutboxWait: Hashable, Sendable {
  public var since: Date
  public var block: TypingBlock?
  /// Whether the coordinator was told the messages are stuck: told once per wait.
  public var told = false

  public init(since: Date, block: TypingBlock? = nil) {
    self.since = since
    self.block = block
  }

  /// How long a child at rest may keep messages untyped before its coordinator is told.
  public static let stuckAfter: TimeInterval = 120

  /// Whether the coordinator is to be told now: the child kept at rest for `stuckAfter`, not told
  /// yet in this wait.
  public func isStuck(at now: Date) -> Bool {
    guard !told, Self.keepsAtRest(block) else { return false }
    return now.timeIntervalSince(since) >= Self.stuckAfter
  }

  /// Whether a block keeps a child at rest from its messages: not its own turn, nor the user's
  /// request, nor its agent stopped.
  public static func keepsAtRest(_ block: TypingBlock?) -> Bool {
    switch block {
    case .recentKeyboard, .panel, .promptText: true
    case .notRunning, .working, .awaitingUser, nil: false
    }
  }
}
