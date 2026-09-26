import Foundation
import VibeDomain

/// What a process knows about its own access to the user's protected folders.
///
/// Two states, not three. macOS exposes no status API for Full Disk Access, and nothing lets a
/// process tell "never asked" from "refused": both look exactly alike from inside. A third case
/// would be an invention, and every screen that read it would be showing a guess.
public enum FullDiskAccessStatus: Hashable, Sendable {
  case granted
  case notGranted
}

/// Answers whether this process has Full Disk Access, without asking for it.
///
/// There is no system call for the question, so the answer is empirical: read something only that
/// access opens. The probe must never be the thing that raises an alert — see
/// `TCCFullDiskAccessProbe` for the witness that was chosen and why it stays silent.
///
/// The answer is the one this process was given **when it started**, and it never changes while
/// it runs (ADR 0010, measured for #76): TCC settles Full Disk Access once for the process
/// responsible, and everything that process spawns inherits it, even after the switch is turned on.
public protocol FullDiskAccessProbe: Sendable {
  func status() async -> FullDiskAccessStatus
}

/// Answers for the application's code identity **now**, rather than for a process that may have
/// started before the user turned the switch on.
///
/// The only way to know is to ask a process born after the fact and answering for itself, so the
/// answer costs a spawn, can take seconds after a rebuild, and may never come: `nil` then.
public protocol CurrentFullDiskAccessProbe: Sendable {
  func status() async -> FullDiskAccessStatus?
}

/// What TCC keys a grant to: the code identity that received it.
///
/// For a certificate-signed application, the bundle identifier, the team and the designated
/// requirement — the requirement is what TCC records, and in an Apple Development build it names
/// the leaf certificate, so another certificate or a move to Developer ID is another application to
/// TCC. For an ad-hoc build only the bundle identifier: its requirement is its own hash, which
/// every compilation changes, and keying on it would bring the step back at each build.
public struct CodeIdentityFingerprint: Hashable, Sendable, RawRepresentable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  /// A signed build.
  public init(identifier: String, team: String, designatedRequirement: String) {
    rawValue = "\(identifier)|\(team)|\(designatedRequirement)"
  }

  /// A build signed ad hoc, or not at all.
  public static func adHoc(identifier: String) -> CodeIdentityFingerprint {
    CodeIdentityFingerprint(rawValue: "adhoc|\(identifier)")
  }

  /// A process whose signature could not be read. Still one identity, so the step it answered
  /// stays answered.
  public static let unidentified = CodeIdentityFingerprint(rawValue: "unidentified")
}

/// Reads what this process is signed as.
public protocol CodeIdentityReading: Sendable {
  func current() -> CodeIdentityFingerprint
}

/// The identity of a process whose signature nobody reads: tests, previews.
public struct UnidentifiedCode: CodeIdentityReading {
  public init() {
    // Nothing to read.
  }

  public func current() -> CodeIdentityFingerprint { .unidentified }
}

/// What the application remembers about permission steps the user has already seen.
///
/// Only decisions the user made are kept here, and each with the code identity that heard it:
/// TCC holds a grant against that identity, and a new identity — another bundle identifier,
/// another team, a Developer ID build after an Apple Development one — starts with nothing. Whether
/// access is granted is never written down: it is read from the system, so an access revoked in
/// System Settings cannot leave the application repeating something that stopped being true.
public protocol PermissionPreferences: Sendable {
  /// The identity that answered the Full Disk Access step, `nil` when none did.
  func fullDiskAccessStepAnswer() async -> CodeIdentityFingerprint?
  func recordFullDiskAccessStepAnswer(by identity: CodeIdentityFingerprint) async
  /// Whoever runs the application asked for the step never to be shown, whatever the identity: an
  /// automated run of the interface, whose signature changes from one machine to the next.
  func isFullDiskAccessStepSuppressed() async -> Bool
}

/// Who answers to TCC for the agents, and how many of them are running there.
public struct AgentRunnerAccess: Equatable, Sendable {
  public enum Runner: Equatable, Sendable {
    /// No agent can run anywhere yet: the next terminal starts a host, born with whatever the
    /// identity has by then.
    case none
    /// The terminal host (ADR 0017).
    case host
    /// The application itself: the host could not be used, or was turned off.
    case application
  }

  public let runner: Runner
  /// What the host said of its own access. `nil` for a host that cannot say — one left running by
  /// an earlier build — and for every other runner.
  public let hostStatus: FullDiskAccessStatus?
  public let runningAgents: Int

  public init(runner: Runner, hostStatus: FullDiskAccessStatus? = nil, runningAgents: Int = 0) {
    self.runner = runner
    self.hostStatus = hostStatus
    self.runningAgents = runningAgents
  }

  public static let none = AgentRunnerAccess(runner: .none)
}

/// What happened when the host was asked to restart.
public enum HostRestart: Equatable, Sendable {
  /// Done, or nothing to do: the next terminal starts a host of its own.
  case restarted
  /// Agents run there: the host restarts once the last of them has ended.
  case armed
}

/// The process that runs the agents, as far as Full Disk Access goes.
public protocol AgentRunnerControl: Sendable {
  func agentRunnerAccess() async -> AgentRunnerAccess
  /// The sessions whose agent runs in the host now.
  func runningHostedSessions() async -> [SessionID]
  /// Lets the host go as soon as no agent runs there, so the next terminal starts one born with
  /// the access. Never stops an agent.
  func restartHostWhenIdle() async -> HostRestart
  func cancelHostRestart() async
  func isHostRestartArmed() async -> Bool
}

/// Where the Full Disk Access granted to the application actually stands.
public enum FullDiskAccessSituation: Equatable, Sendable {
  /// Nothing answered yet. Nothing is said on a guess (ADR 0010).
  case checking
  case granted
  case notGranted
  /// The application has it, and the process that runs the agents started before it did: it
  /// never will until it restarts.
  case pendingRestart(runner: PendingRunner, runningAgents: Int)

  public enum PendingRunner: Equatable, Sendable {
    case host
    case application
  }

  /// | Identity | Runner                        | Situation                      |
  /// |----------|-------------------------------|--------------------------------|
  /// | —        | —                             | `checking`                     |
  /// | ✘        | —                             | `notGranted`                   |
  /// | ✔        | none                          | `granted`                      |
  /// | ✔        | host ✔                        | `granted`                      |
  /// | ✔        | host ✘ or unknown             | `pendingRestart(.host)`        |
  /// | ✔        | application, which has it     | `granted`                      |
  /// | ✔        | application, which does not   | `pendingRestart(.application)` |
  ///
  /// `identity` is what a process born now would get; without it, what this process got at its
  /// launch, which was the identity's answer then.
  public static func resolve(
    identity: FullDiskAccessStatus?,
    interface: FullDiskAccessStatus?,
    runner: AgentRunnerAccess
  ) -> FullDiskAccessSituation {
    guard let current = identity ?? interface else { return .checking }
    guard current == .granted else { return .notGranted }
    switch runner.runner {
    case .none:
      return .granted
    case .host:
      return runner.hostStatus == .granted
        ? .granted : .pendingRestart(runner: .host, runningAgents: runner.runningAgents)
    case .application:
      return interface == .granted
        ? .granted : .pendingRestart(runner: .application, runningAgents: runner.runningAgents)
    }
  }
}

/// The three answers the situation is made of, kept apart so the settings can show each one.
public struct FullDiskAccessReport: Equatable, Sendable {
  /// What a process born now gets, or what this one got at launch until one has answered.
  public let identity: FullDiskAccessStatus?
  /// What this process got at its launch.
  public let interface: FullDiskAccessStatus?
  public let runner: AgentRunnerAccess
  public let situation: FullDiskAccessSituation

  public init(
    identity: FullDiskAccessStatus?,
    interface: FullDiskAccessStatus?,
    runner: AgentRunnerAccess
  ) {
    self.identity = identity
    self.interface = interface
    self.runner = runner
    situation = .resolve(identity: identity, interface: interface, runner: runner)
  }

  /// Whether the answers agree, and there is nothing to explain process by process.
  public var isConsistent: Bool {
    switch situation {
    case .checking, .notGranted: return true
    case .pendingRestart: return false
    case .granted: return interface == .granted
    }
  }
}

/// Decides whether the Full Disk Access step has anything to say, and remembers the answer.
///
/// Three processes answer, and none of them for the others (#76):
///
/// - **this one**, probed once at launch: what it got then was the identity's answer then, and it
///   will not change while it runs;
/// - **a process born now** (`current`), asked when the user may just have turned the switch on;
/// - **the process that runs the agents** (`runner`), which may have started before either.
public actor FullDiskAccessGate {
  private let probe: any FullDiskAccessProbe
  private let current: (any CurrentFullDiskAccessProbe)?
  private let preferences: any PermissionPreferences
  private let identity: any CodeIdentityReading
  private let runner: (any AgentRunnerControl)?
  private var cachedStatus: FullDiskAccessStatus?
  private var currentStatus: FullDiskAccessStatus?
  private var hasPresentedStep = false

  public init(
    probe: any FullDiskAccessProbe,
    preferences: any PermissionPreferences,
    current: (any CurrentFullDiskAccessProbe)? = nil,
    identity: any CodeIdentityReading = UnidentifiedCode(),
    runner: (any AgentRunnerControl)? = nil
  ) {
    self.probe = probe
    self.preferences = preferences
    self.current = current
    self.identity = identity
    self.runner = runner
  }

  /// What this process got at its launch. Probed once: asking again could only repeat it.
  public func status() async -> FullDiskAccessStatus {
    if let cachedStatus { return cachedStatus }
    let status = await probe.status()
    cachedStatus = status
    return status
  }

  /// The identity's answer: asked again of a process born now when `refreshing`, otherwise the
  /// last one it gave, and this process's own until it has given any.
  public func identityStatus(refreshing: Bool) async -> FullDiskAccessStatus {
    if refreshing, let current, let answer = await current.status() {
      currentStatus = answer
    }
    if let currentStatus { return currentStatus }
    return await status()
  }

  /// The three answers, and what they mean together.
  public func report(refreshingIdentity: Bool) async -> FullDiskAccessReport {
    let interface = await status()
    let identity = await identityStatus(refreshing: refreshingIdentity)
    let access = await runner?.agentRunnerAccess() ?? .none
    return FullDiskAccessReport(identity: identity, interface: interface, runner: access)
  }

  /// Whether the one-time step should be presented now.
  ///
  /// | Identity status | Answered by this identity | Presented |
  /// |-----------------|---------------------------|-----------|
  /// | `granted`       | —                         | no        |
  /// | `notGranted`    | no (never, or another)    | **yes**   |
  /// | `notGranted`    | yes                       | no        |
  ///
  /// Presented at most once per launch, whoever asks. Recording the answer is what makes the
  /// step final across launches, but it is written asynchronously, and a second caller reading
  /// the preferences in that window would otherwise be told to present the step all over again.
  public func shouldPresentStep() async -> Bool {
    guard !hasPresentedStep else { return false }
    // Claimed before the first suspension, not after the last one. Both questions below leave the
    // actor, and a guard that latches only on the way out is no guard at all: two callers would
    // cross in that window and both be told to present the step. The claim is given back when the
    // answer turns out to be no, so a later change of heart in the same launch is still heard.
    hasPresentedStep = true
    guard await identityStatus(refreshing: false) == .notGranted else {
      hasPresentedStep = false
      return false
    }
    guard await !preferences.isFullDiskAccessStepSuppressed(),
      await preferences.fullDiskAccessStepAnswer() != identity.current()
    else {
      hasPresentedStep = false
      return false
    }
    return true
  }

  /// Records that this identity answered the step — by granting access or by skipping it. Either
  /// way it is an answer, and an answer is not asked for twice.
  public func dismissStep() async {
    await preferences.recordFullDiskAccessStepAnswer(by: identity.current())
  }
}

/// Stops the agents running in the host and lets the host go, so that they start again in one born
/// with Full Disk Access. Only ever run on the user's word, with the sessions named first.
///
/// It is a quit of those sessions and nothing more: `PrepareForQuit` stops each one **before**
/// writing it closed, and what comes back is the intention to resume them natively (#11), exactly
/// as the next launch would after a clean quit.
public struct RestartAgentHost: Sendable {
  private let quit: PrepareForQuit
  private let repository: any SessionRepository
  private let control: any AgentRunnerControl

  public init(
    repository: any SessionRepository,
    runtime: any SessionRuntime,
    recorder: SessionRuntimeRecorder,
    control: any AgentRunnerControl,
    clock: any SessionClock = SystemSessionClock()
  ) {
    quit = PrepareForQuit(
      repository: repository, runtime: runtime, recorder: recorder, clock: clock)
    self.repository = repository
    self.control = control
  }

  /// The sessions it would stop, most recently worked first — the order they come back in.
  public func sessions() async -> [SessionID] {
    let running = Set(await control.runningHostedSessions())
    let stored = (try? await repository.sessions()) ?? []
    let ordered =
      stored
      .filter { running.contains($0.id) }
      .sorted {
        $0.updatedAt == $1.updatedAt
          ? $0.id.description < $1.id.description : $0.updatedAt > $1.updatedAt
      }
      .map(\.id)
    let known = Set(ordered)
    return ordered
      + running.filter { !known.contains($0) }.sorted { $0.description < $1.description }
  }

  /// Stops exactly the sessions the user was shown — never one started since.
  public func callAsFunction(_ ids: [SessionID]) async -> SessionRestoreIntent {
    let shutdown = await quit.stopAndClose(ids)
    // Idle now, unless an agent was started meanwhile: then it restarts when that one ends.
    _ = await control.restartHostWhenIdle()
    return SessionRestoreIntent(sessionIDs: shutdown.closed.map(\.id))
  }
}
