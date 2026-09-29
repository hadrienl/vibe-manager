import Foundation

/// What the application is doing when an update asks to relaunch it (#92).
public struct UpdateRelaunchSituation: Equatable, Sendable {
  /// Agents running in the terminal host: those that can be left running across the update.
  public var hostedRunningCount: Int
  /// Agents running inside the application, which stop with it whatever the answer.
  public var inProcessRunningCount: Int
  /// The answer to the quit question, when the user asked not to be asked again.
  public var quitBehavior: QuitBehavior
  /// Sessions are being brought back (#11). Leaving now would cancel that.
  public var isRestoring: Bool
  /// A sheet or an alert is open: the user is in the middle of something.
  public var isPresentingModal: Bool
  /// The core of the host protocol this build speaks.
  public var currentHostProtocol: Int
  /// The version about to be installed.
  public var candidate: UpdateCandidate

  public init(
    hostedRunningCount: Int,
    inProcessRunningCount: Int,
    quitBehavior: QuitBehavior,
    isRestoring: Bool,
    isPresentingModal: Bool,
    currentHostProtocol: Int,
    candidate: UpdateCandidate
  ) {
    self.hostedRunningCount = hostedRunningCount
    self.inProcessRunningCount = inProcessRunningCount
    self.quitBehavior = quitBehavior
    self.isRestoring = isRestoring
    self.isPresentingModal = isPresentingModal
    self.currentHostProtocol = currentHostProtocol
    self.candidate = candidate
  }
}

/// What to do about an update that is ready to relaunch the application.
public enum UpdateRelaunchDecision: Equatable, Sendable {
  /// Not now: asked again once nothing is in the way, without a question in between.
  case wait(WaitReason)
  /// Quit, and relaunch, with the agents left running or stopped.
  case proceed(keepingAgentsRunning: Bool)
  /// Ask the user first.
  case ask(Question)

  public enum WaitReason: Equatable, Sendable {
    case restoring
    case modal
  }

  public enum Question: Equatable, Sendable {
    /// The quit question, said of an update: keep them running, stop them, or later.
    case keepOrStop(running: Int, inProcess: Int)
    /// The new version cannot take them back: stop them, or later. Keeping them running is not
    /// offered, since the next launch could not reach them.
    case mustStop(running: Int)
  }
}

/// Installing an update is quitting: the same question, the same two roads (ADR 0017), and the
/// relaunch adopts what was left running. This decides what comes before the quit.
///
/// No session is ever lost in silence. Agents left running are reached by the next version through
/// the frozen core of the host's protocol; a version that speaks another core could not reach
/// them, and says so before anything is installed.
public enum DecideUpdateRelaunch {
  public static func decide(_ situation: UpdateRelaunchSituation) -> UpdateRelaunchDecision {
    if situation.isRestoring { return .wait(.restoring) }
    if situation.isPresentingModal { return .wait(.modal) }

    let running = situation.hostedRunningCount
    guard running > 0 else { return .proceed(keepingAgentsRunning: false) }

    // A feed that does not say is taken at its word: every version so far speaks the one core.
    let compatible =
      situation.candidate.hostProtocol.map { $0 == situation.currentHostProtocol } ?? true
    guard compatible else {
      if situation.quitBehavior == .stopAll { return .proceed(keepingAgentsRunning: false) }
      return .ask(.mustStop(running: running))
    }

    switch situation.quitBehavior {
    case .keepRunning: return .proceed(keepingAgentsRunning: true)
    case .stopAll: return .proceed(keepingAgentsRunning: false)
    case .ask:
      return .ask(.keepOrStop(running: running, inProcess: situation.inProcessRunningCount))
    }
  }
}
