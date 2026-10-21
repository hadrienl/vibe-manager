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
    let said = String(decoding: result.standardError + result.standardOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let detail = said.isEmpty ? nil : String(said.suffix(300))
    // Its exit says whether it signed in: `auth status` still answers `loggedIn` with a token
    // that has expired, which is how the sessions came to fail.
    guard result.termination == .exited(0) else { return .notSignedIn(detail: detail) }
    // And the detection is told: it is what the settings, and the next launch, read.
    let state = await availability(forceRefresh: true).state
    return state == .unauthenticated ? .notSignedIn(detail: detail) : .signedIn
  }
}
