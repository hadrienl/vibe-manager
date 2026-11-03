import Foundation
import VibeApplication

/// `codex login` (#478): the CLI opens the browser and waits for it to come back, for the
/// account of its `CODEX_HOME`. Offered by the settings only: an expired sign-in of Codex is not
/// recognised in its conversations. Its status does not name the account.
extension CodexAgentProvider: AgentSigningIn {
  public var signsInFromConversations: Bool { false }

  public func signIn() async -> AgentSignInOutcome {
    await runSignIn(arguments: ["login"])
  }

  public func signInRoute() async -> AgentSignInRoute { .browser }
}
