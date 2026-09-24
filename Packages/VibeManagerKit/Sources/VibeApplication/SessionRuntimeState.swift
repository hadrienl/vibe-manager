import Darwin
import Foundation
import VibeDomain

/// One running session, as the instance that started it knows it.
///
/// The process group is the child's own identifier — it is a session leader, so a signal sent to
/// the group reaches the whole tree it spawned. It is recorded with the instant the kernel says
/// that process started, because a pid alone identifies nothing: pids are recycled, and a
/// leftover cleaned up on the strength of its number alone would be somebody else's program.
public struct SessionRuntimeRecord: Hashable, Codable, Sendable {
  public let sessionID: SessionID
  public let processGroup: Int32?
  public let processStartedAt: Date?

  public init(sessionID: SessionID, processGroup: Int32? = nil, processStartedAt: Date? = nil) {
    self.sessionID = sessionID
    self.processGroup = processGroup
    self.processStartedAt = processStartedAt?.storageRounded
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID, processGroup, processStartedAt
  }

  /// The identifier is written as the plain UUID string it is. A synthesized encoding would nest
  /// it under `rawValue`, which reads as a mistake in a document meant to be openable by hand.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      sessionID: SessionID(rawValue: try container.decode(UUID.self, forKey: .sessionID)),
      processGroup: try container.decodeIfPresent(Int32.self, forKey: .processGroup),
      processStartedAt: try container.decodeIfPresent(Date.self, forKey: .processStartedAt)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionID.rawValue, forKey: .sessionID)
    try container.encodeIfPresent(processGroup, forKey: .processGroup)
    try container.encodeIfPresent(processStartedAt, forKey: .processStartedAt)
  }
}

/// What the application was running, and whether it was still running when it last wrote this.
///
/// It is deliberately *not* part of the session store. A session is durable work; this is the
/// state of one launch of one copy of the application, and losing it costs a manual restart
/// rather than a session. Written on events — a session started, a session stopped, the
/// application quitting — and never on a timer: after a crash the sessions to resume are already
/// in the store, as the ones left `active`.
public struct SessionRuntimeState: Hashable, Codable, Sendable {
  public enum Phase: String, Codable, Sendable {
    /// An instance holds these sessions. Read back at launch, it means the previous one never
    /// got to say goodbye.
    case running
    /// The instance stopped on purpose, and `sessions` is the intention to resume.
    case stopped
    /// The instance quit and left `sessions` running in the terminal host, each with its process
    /// group; `resuming` holds the ones it stopped instead, to resume as a clean quit would.
    case detached
  }

  public var phase: Phase
  /// The instance that wrote this. `running` with a live pid is not a crash: it is a second copy.
  public var processIdentifier: Int32
  /// When the kernel says that instance started.
  ///
  /// The pid alone identifies nothing — after a restart, or a busy few days, any long-lived
  /// process can be wearing it. Without this, a recycled pid read as a living copy of the
  /// application would block every restoration from then on, and one that happened to equal ours
  /// would make a crashed run look like this very launch.
  public var processStartedAt: Date?
  public var launchedAt: Date
  public var updatedAt: Date
  public var stoppedAt: Date?
  public var sessions: [SessionRuntimeRecord]
  /// The host the sessions were left running in, when the phase is `detached`.
  public var host: TerminalHostIdentity?
  /// Sessions a `detached` quit stopped rather than left running — their process would have died
  /// with the application — and which are resumed the way a clean quit resumes its own.
  public var resuming: [SessionRuntimeRecord]?

  public init(
    phase: Phase,
    processIdentifier: Int32,
    processStartedAt: Date? = nil,
    launchedAt: Date,
    updatedAt: Date,
    stoppedAt: Date? = nil,
    sessions: [SessionRuntimeRecord] = [],
    host: TerminalHostIdentity? = nil,
    resuming: [SessionRuntimeRecord]? = nil
  ) {
    self.phase = phase
    self.processIdentifier = processIdentifier
    self.processStartedAt = processStartedAt?.storageRounded
    self.launchedAt = launchedAt.storageRounded
    self.updatedAt = updatedAt.storageRounded
    self.stoppedAt = stoppedAt?.storageRounded
    self.sessions = sessions
    self.host = host
    self.resuming = resuming
  }

  /// The last instant this document is known to have been written, which is as close as anything
  /// gets to when an unexpected stop happened.
  public var lastSeenAt: Date {
    stoppedAt ?? updatedAt
  }
}

/// The runtime document, seen as a port: nothing that decides needs a disk.
public protocol SessionRuntimeStateStore: Sendable {
  /// `nil` when there is nothing readable — no document, an unreadable one, or one written by a
  /// schema this build does not know. All three mean the same thing here: no intention to honour.
  func read() async -> SessionRuntimeState?
  func write(_ state: SessionRuntimeState) async
  func clear() async
}

/// A runtime document that lives nowhere, for a workspace assembled without the system around it.
public actor EphemeralSessionRuntimeStateStore: SessionRuntimeStateStore {
  private var state: SessionRuntimeState?

  public init(state: SessionRuntimeState? = nil) {
    self.state = state
  }

  public func read() -> SessionRuntimeState? { state }

  public func write(_ state: SessionRuntimeState) { self.state = state }

  public func clear() { state = nil }

  // Nothing else: this store is the whole of what a workspace without a disk remembers.
}

/// Whether the process behind a recorded group is still the one that was recorded.
public enum ProcessIdentity: Equatable, Sendable {
  /// The group exists and started when we said it did.
  case matches
  /// The group exists but started at another time: the pid was recycled, and ours is gone.
  case differs
  /// Nothing answers to that group any more.
  case gone
  /// Something answers, but nothing establishes what it is — no recorded start time, or a
  /// kernel that would not say. Reported, never signalled.
  case unknown
}

/// The only part of the system a leftover check touches, isolated so a test can decide what a
/// process is without spawning one.
public protocol ProcessLivenessProbe: Sendable {
  func isAlive(processIdentifier: Int32) -> Bool
  /// The instant the kernel says this process started, or `nil` when it cannot be told.
  func startTime(of processIdentifier: Int32) -> Date?
  func identify(processGroup: Int32, startedAt: Date?) -> ProcessIdentity
  /// Sends `SIGKILL` to the whole group. Answers whether the kernel accepted the signal.
  @discardableResult
  func terminate(processGroup: Int32) -> Bool
  /// When the Mac last started. A host missing after a restart is not a crash: nothing survives a
  /// restart, and quitting with the agents left running was an intention to carry on.
  func bootTime() -> Date?
}

extension ProcessLivenessProbe {
  /// Identity from the two primitives, so a double only has to answer those.
  ///
  /// The tolerance exists because the two clocks are not the same one: the kernel's start time is
  /// a wall-clock `timeval`, and the recorded one is rounded to the store's millisecond. A pid
  /// recycled within a second of its predecessor's start is not a case worth being wrong about in
  /// the other direction.
  public func identify(processGroup: Int32, startedAt: Date?) -> ProcessIdentity {
    guard isAlive(processIdentifier: processGroup) else { return .gone }
    guard let startedAt, let actual = startTime(of: processGroup) else { return .unknown }
    return abs(actual.timeIntervalSince(startedAt)) < 1 ? .matches : .differs
  }

  /// Unknown unless a probe says otherwise: without it, a missing host always reads as a crash,
  /// which is the answer that asks before resuming anything.
  public func bootTime() -> Date? { nil }
}

public struct SystemProcessLivenessProbe: ProcessLivenessProbe {
  public init() {
    // The system is the state: this probe holds nothing of its own.
  }

  public func isAlive(processIdentifier: Int32) -> Bool {
    guard processIdentifier > 0 else { return false }
    // `EPERM` is an answer too: a process we are not allowed to signal is still a process.
    if kill(processIdentifier, 0) == 0 { return true }
    return errno == EPERM
  }

  public func startTime(of processIdentifier: Int32) -> Date? {
    guard processIdentifier > 0 else { return nil }
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let result = sysctl(&name, UInt32(name.count), &info, &size, nil, 0)
    // A zero-sized answer is a pid the kernel does not know, reported without an error.
    guard result == 0, size > 0, info.kp_proc.p_pid == processIdentifier else { return nil }
    let started = info.kp_proc.p_starttime
    return Date(
      timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
    )
  }

  @discardableResult
  public func terminate(processGroup: Int32) -> Bool {
    guard processGroup > 0 else { return false }
    return kill(-processGroup, SIGKILL) == 0
  }

  public func bootTime() -> Date? {
    var name: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    var value = timeval()
    var size = MemoryLayout<timeval>.stride
    guard sysctl(&name, UInt32(name.count), &value, &size, nil, 0) == 0, value.tv_sec > 0 else {
      return nil
    }
    return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
  }
}
