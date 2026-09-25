import Foundation
import VibeDomain

/// Implemented by the providers whose CLI can report what its agent is doing (#45).
///
/// Each CLI is told how to report in its own terms — settings for one, configuration overrides
/// for the other — so the provider rewrites the plan it produced, and only the shape of what
/// comes back crosses into the application.
public protocol AgentActivityReporting: Sendable {
  /// The same plan, set up to append what its agent does to `log`.
  func reportingActivity(_ plan: AgentLaunchPlan, to log: URL) -> AgentLaunchPlan
  /// Reads the lines this provider's hooks write.
  func activityDecoder() -> any AgentSignalDecoding
}

/// Turns an agent's own reports into signals.
public protocol AgentSignalDecoding: Sendable {
  func signal(for event: AgentActivityEvent) -> AgentSignal?
  /// The single keystrokes that answer a permission in this agent's terminal interface.
  var approvalAnswerKeys: Set<[UInt8]> { get }
  /// What the hooks do not say, read from somewhere else once an event says where: Claude Code
  /// reports no interruption, but writes one into its transcript, whose path its `SessionStart`
  /// carries. `nil` when this event opens no such source.
  func additionalSignals(after event: AgentActivityEvent) -> AsyncStream<AgentSignal>?
}

extension AgentSignalDecoding {
  public func additionalSignals(after event: AgentActivityEvent) -> AsyncStream<AgentSignal>? {
    nil
  }
}

/// Where a session's agent writes its activity, and where it is read back from.
public protocol AgentActivityLogStore: Sendable {
  /// The file a new process of this session reports to, emptied of what a previous one wrote.
  func prepareLog(for id: SessionID) async throws -> URL
  /// The file an adopted process has been reporting to all along.
  func existingLog(for id: SessionID) async -> URL?
  /// Every line written from `position` on, as it arrives. `position` is what a previous reading
  /// stopped at; one that no longer fits the file starts over from its beginning.
  func events(for id: SessionID, from position: AgentActivityLogPosition?) async
    -> AsyncStream<(AgentActivityEvent, AgentActivityLogPosition)>
  func removeLog(for id: SessionID) async
}

/// How far a log was read: the file it was, and the offset reached in it.
public struct AgentActivityLogPosition: Hashable, Codable, Sendable {
  public let fileIdentifier: UInt64
  public let offset: UInt64

  public init(fileIdentifier: UInt64, offset: UInt64) {
    self.fileIdentifier = fileIdentifier
    self.offset = offset
  }
}

/// What survives a relaunch of the application, per session.
public struct PersistedAgentActivity: Hashable, Codable, Sendable {
  public var activity: AgentActivity
  public var unreadSince: Date?
  public var log: AgentActivityLogPosition?

  public init(
    activity: AgentActivity = .idle,
    unreadSince: Date? = nil,
    log: AgentActivityLogPosition? = nil
  ) {
    self.activity = activity
    self.unreadSince = unreadSince
    self.log = log
  }
}

/// The document `agent-activity.json` lives in. Every way of failing to read it answers nothing:
/// losing it costs the unread marks, never a session.
public protocol AgentActivityStateStore: Sendable {
  func read() async -> [SessionID: PersistedAgentActivity]
  func write(_ activities: [SessionID: PersistedAgentActivity]) async
}

/// Implemented by the providers whose CLI asks the user to approve hooks before running them.
public protocol AgentHookTrusting: Sendable {
  /// Whether the hooks `plan` carries will run as they are, asked of the CLI itself.
  func hookTrust(for plan: AgentLaunchPlan) async -> AgentHookTrust
  /// Approves exactly the hooks `plan` carries, and nothing else.
  func trustHooks(of plan: AgentLaunchPlan) async throws
}

public enum AgentHookTrust: Hashable, Sendable {
  case trusted
  /// Some of the hooks need approval; `commands` is what they run, to show before asking.
  case needsApproval(commands: [String])
  /// The CLI could not be asked. The hooks are launched anyway, and the CLI asks for itself.
  case unknown
}
