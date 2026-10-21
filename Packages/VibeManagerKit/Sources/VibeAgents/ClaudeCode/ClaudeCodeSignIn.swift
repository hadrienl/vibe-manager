import Foundation
import VibeApplication
import VibeProcess

/// `claude auth login`, outside any session (#410): the CLI opens the browser on its sign-in page
/// and waits for it to come back. The account it signs in is the one every session uses.
extension ClaudeCodeAgentProvider: AgentSigningIn {
  /// Long enough to sign in by hand, a password manager and a second factor included.
  static let signInTimeout: Duration = .seconds(600)

  public func signIn() async -> AgentSignInOutcome {
    let run = OneShotAgentRun(
      provider: self, runner: BoundedSummaryProcessRunner(), folderPrefix: "vibe-sign-in-",
      timeout: Self.signInTimeout)
    let result: BoundedProcessResult
    do {
      result = try await run.run(
        prepare: { _, _ in
          OneShotAgentRun.Invocation(
            arguments: ["auth", "login"], environment: [:], input: Data())
        },
        read: { result, _ in result })
    } catch is CancellationError {
      return .cancelled
    } catch {
      return .notSignedIn(detail: nil)
    }
    // Asked of the CLI, not read off its exit: the account is what every session needs.
    if await availability(forceRefresh: true).state == .available { return .signedIn }
    let said = String(decoding: result.standardError + result.standardOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return .notSignedIn(detail: said.isEmpty ? nil : String(said.suffix(300)))
  }
}
