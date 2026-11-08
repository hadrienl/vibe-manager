import Foundation
import VibeApplication
import VibeProcess

/// `claude auth login`, outside any session (#410): the CLI opens the browser on its sign-in page
/// and waits for it to come back. The account it signs in is the one every session uses.
extension ClaudeCodeAgentProvider: AgentSigningIn {
  /// Long enough to sign in by hand, a password manager and a second factor included.
  static let signInTimeout: Duration = .seconds(600)

  public func signIn() async -> AgentSignInOutcome {
    await runSignIn(arguments: ["auth", "login"])
  }

  /// What `auth status --json` says of the account. One that cannot be read is taken for a
  /// subscription, the CLI's own default.
  public func signInRoute() async -> AgentSignInRoute {
    await authenticationStatus().map(ClaudeCodeAuthenticationStatus.signInRoute(in:)) ?? .browser
  }

  public func signedInAccount() async -> AgentSignedInAccount? {
    await authenticationStatus().flatMap(ClaudeCodeAuthenticationStatus.account(in:))
  }

  private func authenticationStatus() async -> String? {
    await signInStatus(arguments: ["auth", "status", "--json"]).map {
      String(decoding: $0.standardOutput, as: UTF8.self)
    }
  }

  static let signInRouteTimeout: Duration = .seconds(15)
}

extension AgentProvider {
  /// What the CLI's command `arguments` says of its sign-in; `nil` when it could not run, or was
  /// cancelled.
  func signInStatus(arguments: [String]) async -> BoundedProcessResult? {
    let run = OneShotAgentRun(
      provider: self, runner: BoundedSummaryProcessRunner(), folderPrefix: "vibe-sign-in-",
      timeout: ClaudeCodeAgentProvider.signInRouteTimeout)
    return try? await run.run(
      prepare: { _, _ in
        OneShotAgentRun.Invocation(arguments: arguments, environment: [:], input: Data())
      },
      read: { result, _ in result })
  }

  /// The CLI's own sign-in, until it ends. Its exit says whether it signed in: `auth status` still
  /// answers `loggedIn` with a token that has expired, which is how the sessions came to fail. The
  /// detection is then told: it is what the settings, and the next launch, read.
  func runSignIn(arguments: [String]) async -> AgentSignInOutcome {
    let run = OneShotAgentRun(
      provider: self, runner: BoundedSummaryProcessRunner(), folderPrefix: "vibe-sign-in-",
      timeout: ClaudeCodeAgentProvider.signInTimeout)
    let result: BoundedProcessResult
    do {
      result = try await run.run(
        prepare: { _, _ in
          OneShotAgentRun.Invocation(arguments: arguments, environment: [:], input: Data())
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
    guard result.termination == .exited(0) else { return .notSignedIn(detail: detail) }
    let state = await availability(forceRefresh: true).state
    return state == .unauthenticated ? .notSignedIn(detail: detail) : .signedIn
  }
}
