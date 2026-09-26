import AppKit
import Foundation
import Observation
import VibeApplication
import VibeDomain

/// The application's side of the one permission macOS grants once and for all — and of the
/// processes it has to reach before it is worth anything (#76).
///
/// The switch in System Settings is flipped for the application's code identity, but each process
/// keeps the answer it got when it started. So the model follows three answers: what this window
/// got at launch, what a process born now gets, and what the process that runs the agents got.
/// When the last one lags behind, it says so, and offers to restart that process without ever
/// stopping an agent the user did not name.
@MainActor
@Observable
public final class PermissionsModel {
  /// The pane of System Settings that holds the switch. Opened, never automated: Full Disk Access
  /// cannot be requested programmatically, by design.
  public static let fullDiskAccessSettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
  )!

  /// `nil` until the first probe has answered. "Not probed yet" and "not granted" are different
  /// things, and the settings say so rather than accusing the system of a refusal it has not been
  /// asked about.
  public private(set) var report: FullDiskAccessReport?
  public private(set) var isPresentingStep = false
  /// Set once the user has asked for the host to restart when its last agent ends.
  public private(set) var isRestartArmed = false
  /// The sessions "Restart Now" would stop, while the user is asked to confirm, and the place that
  /// asked: the question is put in that window only.
  public private(set) var pendingRestartNow: RestartNowRequest?
  public private(set) var isRestartingNow = false
  /// Set when the user closed the notice: it does not come back for the same lag.
  public private(set) var isRestartNoticeDismissed = false

  /// Resumes the sessions "Restart Now" stopped, as a clean quit's next launch would. Given by the
  /// workspace, which owns the restoration and its banner.
  var resumeSessions: (@MainActor (SessionRestoreIntent) async -> Void)?
  /// Whether the workspace is resuming sessions. "Restart Now" waits for it: its own resume would
  /// call off that queue, and the sessions it had not reached yet would never come back.
  var isRestoringSessions: (@MainActor () -> Bool)?

  /// Whether "Restart Now" can be asked for now.
  public var canRestartNow: Bool {
    !isRestartingNow && !(isRestoringSessions?() ?? false)
  }

  private let gate: FullDiskAccessGate
  private let control: (any AgentRunnerControl)?
  private let restartHost: RestartAgentHost?
  private let openURL: @MainActor (URL) -> Void
  private let revealApplication: @MainActor () -> Void
  /// Until when coming back to the application is a reason to look again: set by a trip to System
  /// Settings, and bounded, since each look spawns a process and a user who chose not to turn the
  /// switch on would otherwise pay for one at every return for the rest of the run.
  private var awaitsGrantUntil: Date?
  private let now: @MainActor () -> Date
  static let grantWatchDuration: TimeInterval = 10 * 60
  private var restartWatch: Task<Void, Never>?

  public init(
    gate: FullDiskAccessGate,
    control: (any AgentRunnerControl)? = nil,
    restartHost: RestartAgentHost? = nil,
    openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
    revealApplication: @escaping @MainActor () -> Void = {
      NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    },
    now: @escaping @MainActor () -> Date = Date.init
  ) {
    self.now = now
    self.gate = gate
    self.control = control
    self.restartHost = restartHost
    self.openURL = openURL
    self.revealApplication = revealApplication
  }

  /// What the application's identity has, as last known.
  public var status: FullDiskAccessStatus? {
    report?.identity
  }

  public var isGranted: Bool {
    status == .granted
  }

  public var situation: FullDiskAccessSituation {
    report?.situation ?? .checking
  }

  /// What an agent started now gets: the answer that decides whether the creation sheet remarks
  /// on a protected folder. `nil` until known, which stays silent.
  public var agentAccess: FullDiskAccessStatus? {
    switch situation {
    case .checking: return nil
    case .granted: return .granted
    case .notGranted, .pendingRestart: return .notGranted
    }
  }

  /// The notice above the workspace: the access is granted, and agents still run without it.
  public var showsRestartNotice: Bool {
    guard case .pendingRestart = situation else { return false }
    return !isRestartNoticeDismissed
  }

  /// Reads the status and decides whether the step has anything to say. Called at launch — never
  /// from the session-creation flow, which is the whole point.
  ///
  /// This window was just launched, answering for itself, so what it got is what the identity has
  /// now: no process needs to be spawned to know it. It can raise the step but never lowers it:
  /// the gate only ever says yes once per launch, so a second caller asking the question would
  /// otherwise close a step the user is reading.
  public func refresh() async {
    report = await gate.report(refreshingIdentity: false)
    if await gate.shouldPresentStep() {
      isPresentingStep = true
    }
  }

  /// Asks again: the process that runs the agents always, a process born now when
  /// `refreshingIdentity`. An idle host that lags behind is restarted on the spot — nothing runs
  /// there to be interrupted, and the next agent starts with the access.
  public func reevaluate(refreshingIdentity: Bool) async {
    var current = await gate.report(refreshingIdentity: refreshingIdentity)
    if current.situation == .pendingRestart(runner: .host, runningAgents: 0), let control,
      await !control.isHostRestartArmed()
    {
      // An agent started in between: nobody asked to restart after it, so nothing stays armed.
      if await control.restartHostWhenIdle() == .armed { await control.cancelHostRestart() }
      current = await gate.report(refreshingIdentity: false)
    }
    // A new lag is news, even to someone who closed the notice about the previous one. The same
    // lag with one agent fewer is not.
    if Self.lag(of: current.situation) != Self.lag(of: situation) {
      isRestartNoticeDismissed = false
    }
    if current.identity == .granted { awaitsGrantUntil = nil }
    report = current
    isRestartArmed = await control?.isHostRestartArmed() ?? false
  }

  /// The settings opened on this: asks a process born now, since the user has usually just been
  /// to System Settings.
  public func recheck() async {
    await reevaluate(refreshingIdentity: true)
  }

  /// Back in the application. A process born now is asked only within a while of a trip to System
  /// Settings that this window started: it costs a spawn.
  public func applicationDidBecomeActive() async {
    let awaitsGrant = awaitsGrantUntil.map { now() < $0 } ?? false
    if !awaitsGrant { awaitsGrantUntil = nil }
    await reevaluate(refreshingIdentity: awaitsGrant)
  }

  /// Opens the right pane of System Settings, and nothing else.
  ///
  /// Reaching that pane is not an answer to the step: the settings window offers the same button,
  /// and a user who opens it before the step has ever been shown would otherwise lose the step for
  /// good by clicking there and then changing their mind.
  public func openSystemSettings() {
    awaitsGrantUntil = now().addingTimeInterval(Self.grantWatchDuration)
    openURL(Self.fullDiskAccessSettingsURL)
  }

  /// Shows this very copy of the application in the Finder, to be dragged into the list when
  /// System Settings holds several "Vibe Manager" that nothing tells apart.
  public func revealInFinder() {
    revealApplication()
  }

  /// The step's own default button: opens the pane and closes the step. Coming back to the
  /// application is when the answer is looked for.
  public func answerStepByOpeningSystemSettings() async {
    openSystemSettings()
    await dismissStep()
  }

  /// Skipping is an answer too. The application keeps working, and the step is not asked again
  /// by this identity.
  public func skipStep() async {
    await dismissStep()
  }

  public func dismissRestartNotice() {
    isRestartNoticeDismissed = true
  }

  /// Restarts the host once the last agent running there has ended. Nothing is stopped.
  public func restartWhenIdle() async {
    guard let control else { return }
    let outcome = await control.restartHostWhenIdle()
    isRestartArmed = outcome == .armed
    if isRestartArmed { watchArmedRestart() }
    await reevaluate(refreshingIdentity: false)
  }

  public func cancelRestartWhenIdle() async {
    await control?.cancelHostRestart()
    restartWatch?.cancel()
    isRestartArmed = false
  }

  /// Names the sessions "Restart Now" would stop, and waits for the user to confirm.
  public func beginRestartNow(from origin: RestartNowRequest.Origin) async {
    guard let restartHost, canRestartNow else { return }
    let sessions = await restartHost.sessions()
    guard !sessions.isEmpty else { return }
    pendingRestartNow = RestartNowRequest(origin: origin, sessions: sessions)
  }

  public func cancelRestartNow() {
    pendingRestartNow = nil
  }

  /// Stops the agents named, lets the host go, and resumes them in the next one — which is born
  /// with the access. Only ever on the user's confirmation.
  public func confirmRestartNow(_ request: RestartNowRequest) async {
    pendingRestartNow = nil
    guard let restartHost, canRestartNow else { return }
    isRestartingNow = true
    defer { isRestartingNow = false }
    let intent = await restartHost(request.sessions)
    await reevaluate(refreshingIdentity: false)
    await resumeSessions?(intent)
    await reevaluate(refreshingIdentity: false)
  }

  /// Which process lags, without how many agents run there.
  private static func lag(of situation: FullDiskAccessSituation) -> FullDiskAccessSituation
    .PendingRunner?
  {
    guard case .pendingRestart(let runner, _) = situation else { return nil }
    return runner
  }

  private func dismissStep() async {
    isPresentingStep = false
    await gate.dismissStep()
  }

  /// Follows an armed restart until the host has gone, so the notice changes when it happens
  /// rather than the next time the user looks.
  private func watchArmedRestart() {
    restartWatch?.cancel()
    guard let control else { return }
    restartWatch = Task { [weak self] in
      while !Task.isCancelled, await control.isHostRestartArmed() {
        try? await Task.sleep(for: .seconds(2))
      }
      guard !Task.isCancelled else { return }
      await self?.reevaluate(refreshingIdentity: false)
    }
  }
}

/// "Restart Now", asked and not yet confirmed.
public struct RestartNowRequest: Equatable, Sendable {
  public enum Origin: Equatable, Sendable {
    case workspace
    case settings
  }

  public let origin: Origin
  /// Exactly the sessions named to the user, and the only ones stopped.
  public let sessions: [SessionID]
}
