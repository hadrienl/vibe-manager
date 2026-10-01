import Foundation
import VibeApplication
import VibeDomain

/// How the turn or the process of a session the user is not looking at came to an end (#236).
public enum SessionOutcome: Equatable, Sendable {
  /// The agent finished its answer.
  case replied
  /// The process ended on an error: a non-zero exit, a signal, a launch that failed.
  case failed
  /// The process ended cleanly, on its own.
  case stopped
}

/// A system notification about a session's outcome (#236).
public struct SessionOutcomeNotification: Equatable, Sendable {
  public let sessionID: SessionID
  public let outcome: SessionOutcome
  public let title: String
  public let body: String
}

extension AppModel {
  /// Whether the user is looking at this session now: in front, in the main window, selected.
  /// What they see happen needs no word.
  func isOnScreen(_ id: SessionID) -> Bool {
    isApplicationActive && isMainWindowVisible && selectedSessionID == id
  }

  /// An activity update came in: an answer that finished out of sight is said.
  ///
  /// The tracker marks an answer unread only when it ends while the session is not on screen, and
  /// only once until it is read: its first mark is the one transition said. A state seen for the
  /// first time — one restored at launch — says nothing.
  func activityDidChange(
    _ id: SessionID, from previous: AgentActivityState?, to state: AgentActivityState
  ) {
    guard let previous, previous.unreadSince == nil, state.unreadSince != nil else { return }
    sessionDidEnd(id, .replied)
  }

  /// The process of a session ended on its own. One the application stopped — Close, Archive —
  /// says nothing: the user asked for it.
  func processDidEnd(_ id: SessionID, state: TerminalProcessState) {
    if launcher?.pane(for: id)?.wasStoppedOnPurpose == true { return }
    switch state {
    case .exited(let code):
      sessionDidEnd(id, code == 0 ? .stopped : .failed)
    case .terminated, .failed:
      sessionDidEnd(id, .failed)
    case .starting, .running:
      return
    }
  }

  /// VoiceOver hears it; with the application in the background, the Notification Center too.
  func sessionDidEnd(_ id: SessionID, _ outcome: SessionOutcome) {
    guard !isOnScreen(id), let session = sessions.first(where: { $0.id == id }) else { return }
    Announcer.announce(Self.announcement(of: outcome, sessionName: session.name))
    // The floating panel replaces the notifications (#41), as the Settings say.
    let floats = floatingPanel?.isEnabled ?? false
    guard !isApplicationActive, notifiesRequests, !floats, let notifier = requestNotifier else {
      return
    }
    let agent = session.agent.map { agentNames[$0.providerID] ?? $0.providerID }
    notifier.post(
      SessionOutcomeNotification(
        sessionID: id,
        outcome: outcome,
        title: DisplaySafeText.visible([session.name, agent].compactMap { $0 }.joined(separator: " — ")),
        body: String(localized: Self.notificationBody(of: outcome))))
  }

  /// A notification about a session was clicked: the application comes forward on that session.
  public func openSession(_ id: SessionID) {
    guard let session = sessions.first(where: { $0.id == id }) else { return }
    if !isApplicationActive { activateApplication() }
    if session.taskStatus != .archived, filter.column != session.taskStatus {
      setColumn(session.taskStatus)
    }
    select(session.id)
    focusSession()
  }

  static func announcement(of outcome: SessionOutcome, sessionName: String)
    -> LocalizedStringResource
  {
    switch outcome {
    case .replied:
      return LocalizedStringResource(
        "Replied · \(sessionName)", bundle: .module,
        comment: "Said when the agent of a session out of sight finished its answer.")
    case .failed:
      return LocalizedStringResource(
        "Failed · \(sessionName)", bundle: .module,
        comment: "Said when the agent of a session out of sight ended on an error.")
    case .stopped:
      return LocalizedStringResource(
        "Stopped · \(sessionName)", bundle: .module,
        comment: "Said when the agent of a session out of sight ended on its own.")
    }
  }

  static func notificationBody(of outcome: SessionOutcome) -> LocalizedStringResource {
    switch outcome {
    case .replied:
      return LocalizedStringResource(
        "The agent finished its answer.", bundle: .module,
        comment: "A notification: the agent of a session in the background finished its turn.")
    case .failed:
      return LocalizedStringResource(
        "The agent ended on an error.", bundle: .module,
        comment: "A notification: the agent of a session in the background ended on an error.")
    case .stopped:
      return LocalizedStringResource(
        "The agent stopped.", bundle: .module,
        comment: "A notification: the agent of a session in the background ended on its own.")
    }
  }
}
