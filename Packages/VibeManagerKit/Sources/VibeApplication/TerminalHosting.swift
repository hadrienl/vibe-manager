import Foundation
import VibeDomain

/// A terminal whose process lives in the terminal host rather than in the application.
///
/// It is the only kind that can be left running when the application quits: a terminal the
/// application spawned itself shares its fate, and its process group is killed on the way out.
public protocol HostedTerminal: TerminalSession {}

/// Who the terminal host is, as the runtime document records it.
///
/// A pid and the instant the kernel says it started, for the same reason as every other process
/// this application writes down: a pid alone identifies nothing once it has been recycled.
public struct TerminalHostIdentity: Hashable, Codable, Sendable {
  public let processIdentifier: Int32
  public let processStartedAt: Date?

  public init(processIdentifier: Int32, processStartedAt: Date?) {
    self.processIdentifier = processIdentifier
    self.processStartedAt = processStartedAt?.storageRounded
  }
}

/// One session the host holds, as it describes it.
public struct HostedSessionSummary: Equatable, Sendable {
  public let id: SessionID
  public let state: TerminalProcessState
  /// When the process ended, if it has. The host saw it; nobody else was there to.
  public let endedAt: Date?

  public init(id: SessionID, state: TerminalProcessState, endedAt: Date? = nil) {
    self.id = id
    self.state = state
    self.endedAt = endedAt
  }
}

/// What finding the terminal host came to.
public enum TerminalHostStatus: Equatable, Sendable {
  /// No host answers: none was left running, or it did not survive — a restart of the Mac, a
  /// crash, a kill.
  case absent
  /// A host answered, proved it is ours, and holds these sessions.
  case connected(TerminalHostIdentity, sessions: [HostedSessionSummary])
  /// A host that is ours answers, but not to this copy now: another copy is attached, or it did
  /// not answer in time. Its agents may be running: nothing is decided about them.
  case unavailable(reason: String)
  /// Something answers but cannot prove it is one of ours: a host started by a build this one
  /// cannot verify.
  case refused(reason: String)
}

/// The terminal host, seen from the application layer.
///
/// Deciding what to do with what the previous run left running needs a disk, a socket and a
/// signature check; naming the whole of it as a port is what lets the verdicts be tested with none
/// of them.
public protocol TerminalHosting: Sendable {
  /// Finds a host that is already running, without starting one, and takes its sessions over.
  func reconnect() async -> TerminalHostStatus
  /// The host this application is talking to, if any.
  func hostIdentity() async -> TerminalHostIdentity?
  /// Stops a session the host holds and forgets it: something the store no longer wants.
  func discard(_ id: SessionID) async
  /// Says goodbye. `keepRunning` is the one way a session outlives the application: a host that
  /// loses its client without it stops everything, as a crash always has.
  func relinquish(keepRunning: Bool) async
}

/// What quitting with the agents left running needs from the interface.
public protocol SessionHandOff: Sendable {
  /// Lets go of a session without stopping its process, when that process lives somewhere that
  /// outlives the application. Answers `false`, having touched nothing, for a session whose
  /// process would die with the application or is not running.
  func handOff(_ id: SessionID) async -> Bool
}

/// What quitting does to sessions whose agents are running.
public enum QuitBehavior: String, CaseIterable, Sendable {
  case ask
  case keepRunning
  case stopAll
}

/// The answer to the question asked when quitting, when the user asked not to be asked again.
///
/// Read synchronously, like the close confirmation: it decides whether a dialog opens at the very
/// moment the application is asked to terminate.
@MainActor
public protocol QuitPreferences: AnyObject {
  var behavior: QuitBehavior { get set }
}

/// Kept for this run only. What a workspace assembled without the system around it uses.
@MainActor
public final class InMemoryQuitPreferences: QuitPreferences {
  public var behavior: QuitBehavior

  public init(behavior: QuitBehavior = .ask) {
    self.behavior = behavior
  }
}
