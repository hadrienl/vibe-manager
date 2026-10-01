import Foundation
import VibeApplication
import VibeDomain
import VibeTerminalUI

/// A system notification: a session out of sight replied, or its process ended (#236).
public struct SessionOutcomeNotification: Equatable, Sendable {
  public let sessionID: SessionID
  /// The session, and its agent.
  public let title: String
  /// The state the sidebar now shows for it.
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
  /// first time — one restored at launch — says nothing, nor does a line written while the
  /// application was closed and read again on adoption (`isReplayed`). An answer that ends on a
  /// request is said by the request.
  func activityDidChange(
    _ id: SessionID, from previous: AgentActivityState?, to state: AgentActivityState,
    isReplayed: Bool = false
  ) {
    guard !isReplayed, let previous, previous.unreadSince == nil, state.unreadSince != nil,
      state.requests.isEmpty
    else { return }
    sessionDidEnd(id, as: .running, activity: state)
  }

  /// The process of a session ended on its own. One the application stops — Close, Archive, a
  /// switch, quitting — has its watch taken away first, and never comes here.
  func processDidEnd(_ id: SessionID, state: TerminalProcessState) {
    let status: TerminalPaneModel.Status
    switch state {
    case .exited(let code): status = .exited(code: code)
    case .terminated(let signal): status = .terminated(signal: signal)
    case .failed(let error): status = .failed(message: error.errorDescription ?? "")
    case .starting, .running: return
    }
    sessionDidEnd(id, as: status, activity: nil)
  }

  /// Says the state the sidebar now shows for the session — one wording for both — to VoiceOver
  /// and, with the application in the background, in the Notification Center.
  private func sessionDidEnd(
    _ id: SessionID, as status: TerminalPaneModel.Status, activity: AgentActivityState?
  ) {
    guard !isOnScreen(id), let session = sessions.first(where: { $0.id == id }) else { return }
    let state = String(
      localized: SessionStatusPresentation.make(
        session: session, paneStatus: status, activity: activity
      ).label)
    // Waits its turn: several sessions may end together, and a request said just before is not
    // cut.
    Announcer.announce(
      Self.announcement(state: state, sessionName: session.name), priority: .medium)
    // The floating panel replaces the notifications (#41), as the Settings say.
    let floats = floatingPanel?.isEnabled ?? false
    guard !isApplicationActive, notifiesRequests, !floats, let notifier = requestNotifier else {
      return
    }
    let agent = session.agent.map { agentNames[$0.providerID] ?? $0.providerID }
    notifier.postOutcome(
      SessionOutcomeNotification(
        sessionID: id,
        title: DisplaySafeText.visible(
          [session.name, agent].compactMap { $0 }.joined(separator: " — ")),
        body: state))
  }

  /// A notification about a session was clicked: the application shows it as Open Quickly does,
  /// an archived session, or one a filter hides, included.
  public func openFromNotification(_ id: SessionID) {
    goToSession(id)
  }

  static func announcement(state: String, sessionName: String) -> LocalizedStringResource {
    LocalizedStringResource(
      "\(state) · \(sessionName)", bundle: .module,
      comment:
        "Said when a session out of sight replied or its agent ended: the state its row now shows, then its name."
    )
  }
}
