import Foundation
import VibeDomain

/// The window's title (#159).
extension AppModel {
  /// The application, then the session on screen: the one the main area and the inspector show,
  /// archived or not, and the one under a multiple selection (#77). Over a new session's draft
  /// (#177), the draft's name, as its row in the sidebar says it.
  public var windowTitle: WindowTitle {
    WindowTitle(applicationName: applicationName, sessionName: sessionNameOnScreen)
  }

  private var sessionNameOnScreen: String? {
    guard isLoaded else { return nil }
    if isPresentingNewSession, let draft = newSessionModel {
      return draft.draft.trimmedName.isEmpty ? draft.placeholderName : draft.draft.name
    }
    return selectedSession?.name
  }
}
