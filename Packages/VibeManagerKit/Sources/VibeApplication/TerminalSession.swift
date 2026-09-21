import Foundation
import VibeDomain

public struct TerminalSize: Hashable, Sendable {
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

public struct TerminalScrollbackLimits: Hashable, Sendable {
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

public struct TerminalSpec: Hashable, Sendable {
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

public enum TerminalProcessState: Hashable, Sendable {
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

public enum TerminalError: Error, Hashable, LocalizedError, Sendable {
  case executableNotFound(path: String)
  case executableNotPermitted(path: String)
  case notExecutable(path: String)
  case workingDirectoryUnavailable(path: String)
  case pseudoTerminalUnavailable(code: Int32)
  case resourceLimitReached(code: Int32)
  case spawnFailed(code: Int32)
  case sessionAlreadyRunning(SessionID)

  public var errorDescription: String? {
    switch self {
    case .executableNotFound(let path):
      return "No executable was found at \(path)."
    case .executableNotPermitted(let path):
      return "Vibe Manager is not allowed to run \(path)."
    case .notExecutable(let path):
      return "\(path) is not a runnable executable."
    case .workingDirectoryUnavailable(let path):
      return "The working directory \(path) is unavailable."
    case .pseudoTerminalUnavailable:
      return "No pseudo terminal could be allocated."
    case .resourceLimitReached:
      return "The system refused to start another process."
    case .spawnFailed:
      return "The terminal process could not be started."
    case .sessionAlreadyRunning:
      return "A terminal is already running for this work session."
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .executableNotFound:
      return "Check the command, or install the tool and try again."
    case .executableNotPermitted:
      return "Grant execute permission to the file, then try again."
    case .notExecutable:
      return "Select a runnable binary or a script with an interpreter line."
    case .workingDirectoryUnavailable:
      return "Pick a folder that still exists and is readable."
    case .pseudoTerminalUnavailable, .resourceLimitReached:
      return "Close some terminals or applications, then try again."
    case .spawnFailed:
      return "Try again, and report the failure if it persists."
    case .sessionAlreadyRunning:
      return "Stop the running terminal before starting a new one."
    }
  }

  // Technical detail, kept out of the presented message and reserved for explicit export.
  public var diagnosticDetail: String? {
    switch self {
    case .pseudoTerminalUnavailable(let code), .resourceLimitReached(let code),
      .spawnFailed(let code):
      return "errno \(code)"
    case .executableNotFound, .executableNotPermitted, .notExecutable,
      .workingDirectoryUnavailable, .sessionAlreadyRunning:
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

public protocol TerminalSession: Sendable {
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
