import Foundation
import VibeApplication
import VibeDomain
import VibeTerminalUI

/// How much attention a state deserves. The view turns it into a colour; the colour is never
/// the only thing that carries it, because the sidebar also shows the symbol and the words.
public enum SessionStatusSeverity: Equatable, Sendable {
  case normal
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

  public init(label: LocalizedStringResource, symbolName: String, severity: SessionStatusSeverity) {
    self.label = label
    self.symbolName = symbolName
    self.severity = severity
  }

  /// - Parameter wasStoppedOnPurpose: the application asked this process to end — Close or
  ///   Archive. An agent killed that way reports the signal it was killed with (143 for
  ///   `SIGTERM`), which is not a crash and must not be shown as one: the session says "Closed",
  ///   which is what the user just did to it.
  public static func make(
    session: WorkSession,
    paneStatus: TerminalPaneModel.Status?,
    resolution: SessionAgentResolution? = nil,
    wasStoppedOnPurpose: Bool = false
  ) -> SessionStatusPresentation {
    let process = wasStoppedOnPurpose ? nil : paneStatus.flatMap(process)
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
    parts.append(String(localized: status.label))
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
    _ status: TerminalPaneModel.Status
  ) -> SessionStatusPresentation? {
    switch status {
    case .starting:
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Starting", bundle: .module, comment: "A session's state, in the sidebar."),
        symbolName: "hourglass", severity: .normal)
    case .running:
      return SessionStatusPresentation(
        label: LocalizedStringResource(
          "Running", bundle: .module, comment: "A session's state, in the sidebar."),
        symbolName: "play.circle.fill",
        severity: .normal
      )
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
