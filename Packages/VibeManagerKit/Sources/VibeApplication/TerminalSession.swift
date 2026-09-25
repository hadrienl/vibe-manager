import Foundation
import VibeDomain

public struct TerminalSize: Hashable, Codable, Sendable {
  public let columns: Int
  public let rows: Int

  public init(columns: Int, rows: Int) {
    self.columns = columns
    self.rows = rows
  }

  public static let `default` = TerminalSize(columns: 80, rows: 24)

  // A zero column or row count is produced by hidden views and inactive tabs. Forwarding it
  // breaks the layout of full-screen programs, so such a size is never applied.
  public var isUsable: Bool {
    columns > 0 && rows > 0
  }
}

public struct TerminalScrollbackLimits: Hashable, Codable, Sendable {
  public let maximumLineCount: Int
  public let maximumByteCount: Int

  public init(maximumLineCount: Int, maximumByteCount: Int) {
    self.maximumLineCount = max(1, maximumLineCount)
    self.maximumByteCount = max(1, maximumByteCount)
  }

  // A line count alone does not bound memory: a single line can weigh megabytes.
  public static let `default` = TerminalScrollbackLimits(
    maximumLineCount: 5_000,
    maximumByteCount: 4 * 1_024 * 1_024
  )
}

/// `Codable`, like the values around it, because it crosses to the terminal host as it is
/// (ADR 0017): the agent is started there with exactly the environment computed here.
public struct TerminalSpec: Hashable, Codable, Sendable {
  public var executableURL: URL
  public var arguments: [String]
  public var environment: [String: String]
  public var workingDirectoryURL: URL
  public var initialSize: TerminalSize
  public var initialInput: String?
  public var scrollback: TerminalScrollbackLimits

  public init(
    executableURL: URL,
    arguments: [String] = [],
    environment: [String: String] = TerminalEnvironment.make(),
    workingDirectoryURL: URL,
    initialSize: TerminalSize = .default,
    initialInput: String? = nil,
    scrollback: TerminalScrollbackLimits = .default
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.workingDirectoryURL = workingDirectoryURL
    self.initialSize = initialSize
    self.initialInput = initialInput
    self.scrollback = scrollback
  }
}

public enum TerminalProcessState: Hashable, Codable, Sendable {
  case starting
  case running(processIdentifier: Int32)
  case exited(code: Int32)
  case terminated(signal: Int32)
  case failed(TerminalError)

  public var isFinished: Bool {
    switch self {
    case .starting, .running:
      return false
    case .exited, .terminated, .failed:
      return true
    }
  }
}

public enum TerminalEvent: Equatable, Sendable {
  case stateChanged(TerminalProcessState)
  case output([UInt8])
  case historyTruncated(droppedByteCount: Int)
}

public struct TerminalHistorySnapshot: Equatable, Sendable {
  public let bytes: [UInt8]
  public let droppedByteCount: Int

  public init(bytes: [UInt8], droppedByteCount: Int) {
    self.bytes = bytes
    self.droppedByteCount = droppedByteCount
  }
}

public enum TerminalError: Error, Hashable, Codable, LocalizedError, Sendable {
  case executableNotFound(path: String)
  case executableNotPermitted(path: String)
  case notExecutable(path: String)
  case workingDirectoryUnavailable(path: String)
  case pseudoTerminalUnavailable(code: Int32)
  case resourceLimitReached(code: Int32)
  case spawnFailed(code: Int32)
  case sessionAlreadyRunning(SessionID)
  case processOutcomeUnknown(processIdentifier: Int32)
  /// The terminal host already runs as many sessions as it accepts.
  case tooManySessions(limit: Int)
  /// The terminal host went away without a word, and the agent it ran was stopped with it.
  case hostStopped

  public var errorDescription: String? {
    switch self {
    case .executableNotFound(let path):
      return String(localized: "No executable was found at \(path).", bundle: .module)
    case .executableNotPermitted(let path):
      return String(localized: "Vibe Manager is not allowed to run \(path).", bundle: .module)
    case .notExecutable(let path):
      return String(localized: "\(path) is not a runnable executable.", bundle: .module)
    case .workingDirectoryUnavailable(let path):
      return String(localized: "The working directory \(path) is unavailable.", bundle: .module)
    case .pseudoTerminalUnavailable:
      return String(localized: "No pseudo terminal could be allocated.", bundle: .module)
    case .resourceLimitReached:
      return String(localized: "The system refused to start another process.", bundle: .module)
    case .spawnFailed:
      return String(localized: "The terminal process could not be started.", bundle: .module)
    case .sessionAlreadyRunning:
      return String(
        localized: "A terminal is already running for this work session.", bundle: .module)
    case .processOutcomeUnknown:
      return String(
        localized: "The terminal process stopped responding and its outcome is unknown.",
        bundle: .module)
    case .tooManySessions(let limit):
      return String(
        localized: "Vibe Manager already runs \(limit) terminals, the most it runs at once.",
        bundle: .module)
    case .hostStopped:
      return String(
        localized: "The terminal host stopped, and this agent was stopped with it.", bundle: .module
      )
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .executableNotFound:
      return String(
        localized: "Check the command, or install the tool and try again.", bundle: .module)
    case .executableNotPermitted:
      return String(
        localized: "Grant execute permission to the file, then try again.", bundle: .module)
    case .notExecutable:
      return String(
        localized: "Select a runnable binary or a script with an interpreter line.", bundle: .module
      )
    case .workingDirectoryUnavailable:
      return String(localized: "Pick a folder that still exists and is readable.", bundle: .module)
    case .pseudoTerminalUnavailable, .resourceLimitReached:
      return String(
        localized: "Close some terminals or applications, then try again.", bundle: .module)
    case .spawnFailed:
      return String(localized: "Try again, and report the failure if it persists.", bundle: .module)
    case .sessionAlreadyRunning:
      return String(
        localized: "Stop the running terminal before starting a new one.", bundle: .module)
    case .processOutcomeUnknown:
      return String(
        localized: "Check Activity Monitor for a leftover process, then start a new terminal.",
        bundle: .module)
    case .tooManySessions:
      return String(
        localized: "Close a session you no longer need, then try again.", bundle: .module)
    case .hostStopped:
      return String(
        localized: "Restart the session: its conversation is resumed where the agent supports it.",
        bundle: .module)
    }
  }

  // Technical detail, kept out of the presented message and reserved for explicit export.
  public var diagnosticDetail: String? {
    switch self {
    case .pseudoTerminalUnavailable(let code), .resourceLimitReached(let code),
      .spawnFailed(let code):
      return "errno \(code)"
    case .processOutcomeUnknown(let processIdentifier):
      return "pid \(processIdentifier)"
    case .tooManySessions(let limit):
      return "limit \(limit)"
    case .executableNotFound, .executableNotPermitted, .notExecutable,
      .workingDirectoryUnavailable, .sessionAlreadyRunning, .hostStopped:
      return nil
    }
  }
}

public struct TerminalAttachment: Sendable {
  public let state: TerminalProcessState
  public let history: TerminalHistorySnapshot
  public let events: AsyncStream<TerminalEvent>

  public init(
    state: TerminalProcessState,
    history: TerminalHistorySnapshot,
    events: AsyncStream<TerminalEvent>
  ) {
    self.state = state
    self.history = history
    self.events = events
  }
}

/// One process behind one terminal.
///
/// `AnyObject` is part of the contract: a session's `id` is the identifier of the *work* session,
/// which outlives the process, so a restart hands out a new session object under the same id.
/// Anything that caches an attachment has to tell those apart by object identity.
public protocol TerminalSession: AnyObject, Sendable {
  var id: SessionID { get }

  // A view needs the backlog and the live stream as one consistent value: reading them
  // separately would lose whatever arrives between the two calls.
  func attach() async -> TerminalAttachment
  func state() async -> TerminalProcessState
  func history() async -> TerminalHistorySnapshot
  func write(_ bytes: [UInt8]) async
  func resize(to size: TerminalSize) async
  func stop(gracePeriod: Duration) async
  func kill() async
}

extension TerminalSession {
  public func write(_ text: String) async {
    await write([UInt8](text.utf8))
  }

  public func stop() async {
    await stop(gracePeriod: .seconds(3))
  }
}

public protocol TerminalSupervisor: Sendable {
  func start(_ spec: TerminalSpec, for id: SessionID) async throws -> any TerminalSession
  func session(for id: SessionID) async -> (any TerminalSession)?
  func stop(id: SessionID, gracePeriod: Duration) async
  func stopAll(gracePeriod: Duration) async
}
