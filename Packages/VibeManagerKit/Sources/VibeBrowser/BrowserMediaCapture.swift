import WebKit

/// What a page that asks for the microphone or the camera gets (#315).
///
/// The microphone only: the application declares no use of the camera. A page of the user's is
/// asked by WebKit, then by macOS the first time; a page the agent drives is asked by the question
/// of the agent's effects (#241), since nothing the agent does may reach the microphone unasked.
enum BrowserMediaCapture {
  enum Decision: Equatable {
    /// WebKit asks the user, in the tab.
    case prompt
    /// The question of the agent's effects asks the user.
    case askUser
    /// Refused without a question; the page is told why in its console.
    case deny(reason: String)
  }

  static func decide(_ type: WKMediaCaptureType, asksBeforeEffects: Bool, isOnScreen: Bool)
    -> Decision
  {
    guard type == .microphone else {
      return .deny(reason: "Camera refused: Vibe Manager gives pages the microphone only.")
    }
    if asksBeforeEffects { return .askUser }
    // WebKit's question would open in a window out of sight, and the page would wait for ever.
    guard isOnScreen else {
      return .deny(reason: "Microphone refused: the tab is not shown.")
    }
    return .prompt
  }
}
