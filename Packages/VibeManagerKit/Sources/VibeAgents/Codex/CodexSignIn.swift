import Foundation
import VibeApplication
import VibeProcess

/// `codex login` (#478): the CLI opens the browser and waits for it to come back, for the
/// account of its `CODEX_HOME`. Offered by the settings only: an expired sign-in of Codex is not
/// recognised in its conversations. Its status does not name the account.
extension CodexAgentProvider: AgentSigningIn {
  public var signsInFromConversations: Bool { false }

  public func signIn() async -> AgentSignInOutcome {
    await runSignIn(arguments: ["login"])
  }

  /// What `codex login status` says. A status that cannot be read is taken for ChatGPT, the CLI's
  /// own default.
  public func signInRoute() async -> AgentSignInRoute {
    await signInStatus(arguments: ["login", "status"]).map {
      CodexLoginStatus.signInRoute(
        in: String(decoding: $0.standardError + $0.standardOutput, as: UTF8.self))
    } ?? .browser
  }
}

/// How `codex login status` says the CLI is signed in, on its error output (0.166): "Logged in
/// using ChatGPT", "Not logged in", or else a key ("API key configured - sk-…"), a token, Bedrock
/// or a workload identity.
enum CodexLoginStatus {
  /// `codex login` signs ChatGPT in, in the browser: it would replace a key or a token with it,
  /// which signing in again is not meant to change.
  static func signInRoute(in status: String) -> AgentSignInRoute {
    if status.contains("Logged in using ChatGPT") || status.contains("Not logged in") {
      return .browser
    }
    if status.contains("API key configured") || status.contains("Logged in using") {
      return .elsewhere
    }
    return .browser
  }
}
