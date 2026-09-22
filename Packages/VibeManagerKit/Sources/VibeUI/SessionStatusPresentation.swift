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
  public let label: String
  public let symbolName: String
  public let severity: SessionStatusSeverity

  public init(label: String, symbolName: String, severity: SessionStatusSeverity) {
    self.label = label
    self.symbolName = symbolName
    self.severity = severity
  }

  public static func make(
    session: WorkSession,
    paneStatus: TerminalPaneModel.Status?,
    resolution: SessionAgentResolution? = nil
  ) -> SessionStatusPresentation {
    let process = paneStatus.flatMap(process)

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

    switch session.status {
    case .active:
      // Stored as active with nothing running here: the session is real, its terminal is not.
      return SessionStatusPresentation(
        label: "Not running",
        symbolName: "pause.circle",
        severity: .normal
      )
    case .closed:
      return SessionStatusPresentation(
        label: "Closed", symbolName: "stop.circle", severity: .normal)
    case .archived:
      return SessionStatusPresentation(
        label: "Archived",
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
    parts.append(status.label)
    return parts.joined(separator: ", ")
  }

  /// What the process itself says. `nil` means it says nothing the sidebar should show, and the
  /// stored status is left to speak.
  /// Whether a terminal's own state is worth more than what its agent can do: it is running, or
  /// it ended badly. A clean exit is neither, and steps aside for a missing agent.
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
        label: "Starting", symbolName: "hourglass", severity: .normal)
    case .running:
      return SessionStatusPresentation(
        label: "Running",
        symbolName: "play.circle.fill",
        severity: .normal
      )
    case .exited(let code) where code == 0:
      return SessionStatusPresentation(
        label: "Finished",
        symbolName: "checkmark.circle",
        severity: .normal
      )
    case .exited(let code):
      return SessionStatusPresentation(
        label: "Exited with code \(code)",
        symbolName: "exclamationmark.triangle.fill",
        severity: .error
      )
    case .terminated(let signal):
      return SessionStatusPresentation(
        label: "Terminated by signal \(signal)",
        symbolName: "exclamationmark.triangle.fill",
        severity: .error
      )
    case .failed:
      return SessionStatusPresentation(
        label: "Failed",
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
        label: "Agent unavailable",
        symbolName: "bolt.horizontal.circle",
        severity: .attention
      )
    case .ready, .unassigned:
      return nil
    }
  }
}
