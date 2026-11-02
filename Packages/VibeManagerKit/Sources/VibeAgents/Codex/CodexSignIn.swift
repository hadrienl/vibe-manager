import Foundation
import VibeApplication
import VibeProcess

/// `codex login` (#478): the CLI opens the browser and waits for it to come back, for the
/// account of its `CODEX_HOME`. Offered by the settings only: an expired sign-in of Codex is not
/// recognised in its conversations. Its status does not name the account.
extension CodexAgentProvider: AgentSigningIn {
  public var signsInFromConversations: Bool { false }

  public func signIn() async -> AgentSignInOutcome {
    let run = OneShotAgentRun(
      provider: self, runner: BoundedSummaryProcessRunner(), folderPrefix: "vibe-sign-in-",
      timeout: ClaudeCodeAgentProvider.signInTimeout)
    let result: BoundedProcessResult
    do {
      result = try await run.run(
        prepare: { _, _ in
          OneShotAgentRun.Invocation(arguments: ["login"], environment: [:], input: Data())
        },
        read: { result, _ in result })
    } catch is CancellationError {
      return .cancelled
    } catch {
      return .notSignedIn(detail: nil)
    }
    let said = String(decoding: result.standardError + result.standardOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.termination == .exited(0) else {
      return .notSignedIn(detail: said.isEmpty ? nil : String(said.suffix(300)))
    }
    let state = await availability(forceRefresh: true).state
    return state == .unauthenticated ? .notSignedIn(detail: nil) : .signedIn
  }

  public func signInRoute() async -> AgentSignInRoute { .browser }
}
