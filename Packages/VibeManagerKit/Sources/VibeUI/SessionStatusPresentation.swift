import Foundation
import VibeApplication
import VibeDomain
import VibeTerminalUI

/// How much attention a state deserves. The view turns it into a colour; the colour is never
/// the only thing that carries it, because the sidebar also shows the symbol and the words.
public enum SessionStatusSeverity: Equatable, Sendable {
  case normal
  /// The agent is working: the accent colour, which draws the eye less than a warning.
  case active
  case attention
  case error
}

/// What a session looks like in the sidebar, resolved from three sources that disagree.
///
/// A session is stored active, its terminal may have died, and its agent may have disappeared
/// from the machine since. The stored status is the weakest of the three: it says what the user
/// intended, while the pane says what actually happened.
public struct SessionStatusPresentation: Equatable, Sendable {
  public let label: LocalizedStringResource
  public let symbolName: String
  public let severity: SessionStatusSeverity
  /// What the agent is doing, when the headline is about it rather than about its process.
  public let agentActivity: AgentActivity?
  /// The agent waits for the user — a question, a permission, an answer not read yet (#45).
  public let needsAttention: Bool
  /// The process is starting, or being restored: something is under way, nothing to read yet.
  public let isStarting: Bool

  public init(
    label: LocalizedStringResource,
    symbolName: String,
    severity: SessionStatusSeverity,
    agentActivity: AgentActivity? = nil,
    needsAttention: Bool = false,
    isStarting: Bool = false
  ) {
    self.label = label
    self.symbolName = symbolName
    self.severity = severity
    self.agentActivity = agentActivity
    self.needsAttention = needsAttention
    self.isStarting = isStarting
  }

  /// What a session being restored shows: said on its row, and counted in its group.
  public static let restoring = SessionStatusPresentation(
    label: LocalizedStringResource(
      "Restoring…", bundle: .module, comment: "A session's state, in the sidebar."),
    symbolName: "arrow.clockwise", severity: .normal, isStarting: true)

  /// Whether the symbol moves: only a working agent's does, and never with Reduce Motion on.
  public var isAnimated: Bool {
    agentActivity == .working
  }

  /// - Parameter wasStoppedOnPurpose: the application asked this process to end — Close or
  ///   Archive. An agent killed that way reports the signal it was killed with (143 for
  ///   `SIGTERM`), which is not a crash and must not be shown as one: the session says "Closed",
  ///   which is what the user just did to it.
  /// - Parameter activity: what the agent of a running process is doing (#45). It takes the place
  ///   of "Running" only: starting, restoring, an exit that went wrong and a missing agent say
  ///   more, and keep their place above it.
  public static func make(
    session: WorkSession,
    paneStatus: TerminalPaneModel.Status?,
    resolution: SessionAgentResolution? = nil,
    wasStoppedOnPurpose: Bool = false,
    activity: AgentActivityState? = nil
  ) -> SessionStatusPresentation {
    // The closure's type is written out: Xcode 16.4 cannot infer it on its own.
    let process: SessionStatusPresentation? =
      wasStoppedOnPurpose
      ? nil
      : paneStatus.flatMap { status -> SessionStatusPresentation? in
        Self.process(status, activity: activity)
      }
    if wasStoppedOnPurpose, let paneStatus, hasEnded(paneStatus) {
      return stored(session)
    }

    // A terminal that is live, or that ended badly, says more than a detection: it reports what
    // just happened here. Only once nothing is running, and nothing went wrong, does a missing
    // agent become the session's headline — a terminal that simply finished must not hide it.
    if let paneStatus, let process, outranksResolution(paneStatus) {
      return process
    }

    if let resolution, let unavailable = unavailableAgent(resolution) {
      return unavailable
    }

    if let process {
      return process
    }

    return stored(session)
  }

  /// What the store says, for a session with nothing to report about a process.
  private static func stored(_ session: WorkSession) -> SessionStatusPresentation {
    switch session.status {
    case .active:
      // Stored as active with nothing running here: the session is real, its terminal is not.
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Not running", bundle: .module, comment: "A session's state, in the sidebar."),
        symbolName: "pause.circle",
        severity: .normal
      )
    case .closed:
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Closed", bundle: .module,
          comment: "A session's state in the sidebar; also labels the date it took that state."),
        symbolName: "stop.circle", severity: .normal)
    case .archived:
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Archived", bundle: .module,
          comment: "A session's state in the sidebar; also labels the date it took that state."),
        symbolName: "archivebox",
        severity: .normal
      )
    }
  }

  /// The label read out by VoiceOver, where the symbol and the colour say nothing.
  public static func accessibilityLabel(
    for session: WorkSession,
    status: SessionStatusPresentation
  ) -> String {
    var parts = [session.name]
    if let agent = session.agent {
      // A session may have no model of its own: the agent then uses whatever it is configured
      // with, and naming a model here would be inventing one.
      parts.append([agent.providerID, agent.modelID].compactMap { $0 }.joined(separator: " "))
    }
    let state = String(localized: status.label)
    parts.append(
      status.needsAttention
        ? String(
          localized: "Needs attention: \(state)", bundle: .module,
          comment:
            "Read out by VoiceOver before what the agent waits for: a question, an approval, an unread answer."
        )
        : state)
    return parts.joined(separator: ", ")
  }

  /// What the process itself says. `nil` means it says nothing the sidebar should show, and the
  /// stored status is left to speak.
  /// Whether a terminal's own state is worth more than what its agent can do: it is running, or
  /// it ended badly. A clean exit is neither, and steps aside for a missing agent.
  private static func hasEnded(_ status: TerminalPaneModel.Status) -> Bool {
    switch status {
    case .starting, .running:
      return false
    case .exited, .terminated, .failed:
      return true
    }
  }

  private static func outranksResolution(_ status: TerminalPaneModel.Status) -> Bool {
    switch status {
    case .starting, .running, .terminated, .failed:
      return true
    case .exited(let code):
      return code != 0
    }
  }

  private static func process(
    _ status: TerminalPaneModel.Status,
    activity: AgentActivityState?
  ) -> SessionStatusPresentation? {
    switch status {
    case .starting:
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Starting", bundle: .module, comment: "A session's state, in the sidebar."),
        symbolName: "hourglass", severity: .normal, isStarting: true)
    case .running:
      return agent(activity ?? AgentActivityState())
    case .exited(let code) where code == 0:
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Finished", bundle: .module, comment: "A session's state, in the sidebar."),
        symbolName: "checkmark.circle",
        severity: .normal
      )
    case .exited(let code):
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Exited with code \(String(code))", bundle: .module,
          comment: "A session's state: its agent ended with this exit status."),
        symbolName: "exclamationmark.triangle.fill",
        severity: .error
      )
    case .terminated(let signal):
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Terminated by signal \(String(signal))", bundle: .module,
          comment: "A session's state: its agent was killed by this signal number."),
        symbolName: "exclamationmark.triangle.fill",
        severity: .error
      )
    case .failed:
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Failed", bundle: .module, comment: "A session's state, in the sidebar."),
        symbolName: "exclamationmark.triangle.fill",
        severity: .error
      )
    }
  }

  /// What the agent of a running process is doing. A question comes first, then an answer not
  /// read yet — unless the agent went back to work since, which it then says instead.
  private static func agent(_ state: AgentActivityState) -> SessionStatusPresentation {
    switch state.activity {
    case .awaitingUser(.approval):
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Needs approval", bundle: .module,
          comment: "A session's state: its agent waits for the user to allow a tool or a plan."),
        symbolName: "hand.raised.fill", severity: .attention,
        agentActivity: state.activity, needsAttention: true)
    case .awaitingUser(.question):
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Has a question", bundle: .module,
          comment: "A session's state: its agent asked the user something and waits for the answer."
        ),
        symbolName: "questionmark.bubble.fill", severity: .attention,
        agentActivity: state.activity, needsAttention: true)
    case .working:
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Working", bundle: .module,
          comment: "A session's state: its agent is generating, or running a tool."),
        symbolName: "arrow.triangle.2.circlepath", severity: .active,
        agentActivity: state.activity)
    case .idle where state.unreadSince != nil:
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "New reply", bundle: .module,
          comment: "A session's state: its agent finished an answer the user has not seen yet."),
        symbolName: "text.bubble.fill", severity: .attention,
        agentActivity: state.activity, needsAttention: true)
    case .idle:
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Idle", bundle: .module,
          comment: "A session's state: its agent waits for an instruction, with nothing to read."),
        symbolName: "moon.zzz", severity: .normal, agentActivity: state.activity)
    }
  }

  private static func unavailableAgent(
    _ resolution: SessionAgentResolution
  ) -> SessionStatusPresentation? {
    switch resolution {
    case .unavailable, .unknownProvider:
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Agent unavailable", bundle: .module, comment: "A session's state, in the sidebar."),
        symbolName: "bolt.horizontal.circle",
        severity: .attention
      )
    case .ready, .unassigned:
      return nil
    }
  }
}
