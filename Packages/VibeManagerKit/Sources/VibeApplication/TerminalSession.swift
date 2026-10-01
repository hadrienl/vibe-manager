import Foundation
import VibeDomain

/// One terminal: the agent's own, or one of the side terminals a session keeps in its drawer
/// (#43).
///
/// A session used to have exactly one terminal, and every port below was keyed by its
/// `SessionID`. The agent's terminal keeps that very UUID (`SessionID.agentTerminal`), so the
/// terminal host's frozen protocol — sixteen bytes of identifier — and everything recorded under
/// it are unchanged; a side terminal has a UUID of its own. `Codable` exactly as `SessionID` is,
/// so the two encode to the same JSON on the wire.
public struct TerminalID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public var description: String {
    rawValue.uuidString
  }
}

extension SessionID {
  /// The terminal the session's agent runs in, which carries the session's own UUID.
  public var agentTerminal: TerminalID {
    TerminalID(rawValue: rawValue)
  }
}

extension TerminalID {
  /// The session whose agent runs in this terminal, if it is one — read from the UUID alone. A
  /// side terminal answers a session that does not exist.
  public var agentSession: SessionID {
    SessionID(rawValue: rawValue)
  }
}

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

/// What a terminal is for.
///
/// Told apart because they are not counted alike: an agent is what quitting asks about and what a
/// restart of the host waits for, while a shell in a session's drawer (#43) is always "running" —
/// an idle prompt — and counting it would keep the host from ever being idle.
public enum TerminalRole: String, Hashable, Codable, Sendable {
  case agent
  /// A shell in a session's drawer of side terminals (#43).
  case auxiliary
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
  public var role: TerminalRole

  public init(
    executableURL: URL,
    arguments: [String] = [],
    environment: [String: String] = TerminalEnvironment.make(),
    workingDirectoryURL: URL,
    initialSize: TerminalSize = .default,
    initialInput: String? = nil,
    scrollback: TerminalScrollbackLimits = .default,
    role: TerminalRole = .agent
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.workingDirectoryURL = workingDirectoryURL
    self.initialSize = initialSize
    self.initialInput = initialInput
    self.scrollback = scrollback
    self.role = role
  }

  /// `role` is read when present: a spec written by a build that predates it is an agent's, the
  /// only kind of terminal there was.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    executableURL = try container.decode(URL.self, forKey: .executableURL)
    arguments = try container.decode([String].self, forKey: .arguments)
    environment = try container.decode([String: String].self, forKey: .environment)
    workingDirectoryURL = try container.decode(URL.self, forKey: .workingDirectoryURL)
    initialSize = try container.decode(TerminalSize.self, forKey: .initialSize)
    initialInput = try container.decodeIfPresent(String.self, forKey: .initialInput)
    scrollback = try container.decode(TerminalScrollbackLimits.self, forKey: .scrollback)
    role = try container.decodeIfPresent(TerminalRole.self, forKey: .role) ?? .agent
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
  /// This subscriber fell behind and lost blocks of output its stream had not delivered yet
  /// (#248). Unlike `historyTruncated`, the bytes are still in the session's history: a reader
  /// that keeps its place in the stream counts them as passed, and can read them from there.
  case outputDropped(byteCount: Int)
  /// The terminal wrote something, told instead of the bytes to a subscriber that only needs to
  /// know it did (#248): see `TerminalEventInterest.pulses`.
  case outputPulse
}

/// What a subscriber reads of a terminal (#248).
///
/// Every subscriber used to be handed every block of output, and each one that runs on the main
/// actor woke it for it: five times a block for an agent's terminal, whether its view was on screen
/// or not. A subscriber now says what it reads, and the session serves nothing else.
public enum TerminalEventInterest: Hashable, Sendable {
  /// Every event: the view, and the observers that read the text.
  case everything
  /// State changes only: the exit watch, the pane's status.
  case state
  /// State changes, and `.outputPulse` in place of the bytes — at once on the first output, then
  /// at most once per `interval`, and always once more after the last output of a burst, so that
  /// a subscriber scheduling work on output never misses the end of it.
  case pulses(every: Duration)

  /// The event this interest is served in place of `event`, if any: for a session that has no
  /// cadence of its own to keep, such as a stand-in, pulses are not spaced out.
  public func translating(_ event: TerminalEvent) -> TerminalEvent? {
    switch (self, event) {
    case (.everything, _), (_, .stateChanged):
      return event
    case (.pulses, .output), (.pulses, .outputPulse):
      return .outputPulse
    case (.state, _), (.pulses, .historyTruncated), (.pulses, .outputDropped):
      return nil
    }
  }
}

public struct TerminalHistorySnapshot: Equatable, Sendable {
  public let bytes: [UInt8]
  public let droppedByteCount: Int
  /// Where `bytes` starts in the stream of output this session delivered (#248): how many bytes it
  /// had delivered before them. A view that remembers how far it fed can take only what follows.
  public let startOffset: Int

  public init(bytes: [UInt8], droppedByteCount: Int, startOffset: Int = 0) {
    self.bytes = bytes
    self.droppedByteCount = droppedByteCount
    self.startOffset = startOffset
  }

  /// Where the stream goes on after `bytes`: the first byte a live event will bring.
  public var endOffset: Int { startOffset + bytes.count }
}

public enum TerminalError: Error, Hashable, Codable, LocalizedError, Sendable {
  case executableNotFound(path: String)
  case executableNotPermitted(path: String)
  case notExecutable(path: String)
  case workingDirectoryUnavailable(path: String)
  case pseudoTerminalUnavailable(code: Int32)
  case resourceLimitReached(code: Int32)
  case spawnFailed(code: Int32)
  case sessionAlreadyRunning(TerminalID)
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
  var id: TerminalID { get }

  // A view needs the backlog and the live stream as one consistent value: reading them
  // separately would lose whatever arrives between the two calls.
  func attach() async -> TerminalAttachment
  /// The same, with only the events `interest` reads in the stream (#248).
  func attach(_ interest: TerminalEventInterest) async -> TerminalAttachment
  /// When the process last wrote something, noted by the session itself as the output arrives, so
  /// that nobody has to watch every block for it (#248).
  func lastOutputAt() async -> ContinuousClock.Instant?
  func state() async -> TerminalProcessState
  func history() async -> TerminalHistorySnapshot
  func write(_ bytes: [UInt8]) async
  func resize(to size: TerminalSize) async
  func stop(gracePeriod: Duration) async
  func kill() async
  /// Whether the process runs in the terminal host: its outcome is unknown, then, only when the
  /// host itself went away (#237).
  var runsInTerminalHost: Bool { get }
}

extension TerminalSession {
  public var runsInTerminalHost: Bool { false }

  /// Relays the full stream, keeping only what `interest` reads: for a session that serves one
  /// stream to all, as the stand-ins of the tests do. The real sessions filter at the source.
  public func attach(_ interest: TerminalEventInterest) async -> TerminalAttachment {
    let attachment = await attach()
    guard interest != .everything else { return attachment }
    let (events, continuation) = AsyncStream<TerminalEvent>.makeStream()
    let relay = Task {
      for await event in attachment.events {
        if let translated = interest.translating(event) { continuation.yield(translated) }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in relay.cancel() }
    return TerminalAttachment(state: attachment.state, history: attachment.history, events: events)
  }

  public func lastOutputAt() async -> ContinuousClock.Instant? { nil }

  public func write(_ text: String) async {
    await write([UInt8](text.utf8))
  }

  public func stop() async {
    await stop(gracePeriod: .seconds(3))
  }
}

public protocol TerminalSupervisor: Sendable {
  func start(_ spec: TerminalSpec, for id: TerminalID) async throws -> any TerminalSession
  func session(for id: TerminalID) async -> (any TerminalSession)?
  func stop(id: TerminalID, gracePeriod: Duration) async
  func stopAll(gracePeriod: Duration) async
}

/// The agent's terminal of a session, named by the session: what every caller that predates the
/// side terminals speaks.
extension TerminalSupervisor {
  public func start(_ spec: TerminalSpec, for id: SessionID) async throws -> any TerminalSession {
    try await start(spec, for: id.agentTerminal)
  }

  public func session(for id: SessionID) async -> (any TerminalSession)? {
    await session(for: id.agentTerminal)
  }

  public func stop(id: SessionID, gracePeriod: Duration) async {
    await stop(id: id.agentTerminal, gracePeriod: gracePeriod)
  }
}
