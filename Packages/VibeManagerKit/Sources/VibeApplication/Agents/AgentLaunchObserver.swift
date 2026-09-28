import VibeDomain

/// What watches one launch long enough to keep what makes it resumable.
///
/// The two CLIs reveal their session identifier in ways that have nothing in common — one is
/// told which identifier to use, the other has to be discovered — so the knowledge stays inside
/// each provider and only this shape crosses into the application.
public protocol AgentLaunchObserver: Sendable {
  func launched(plan: AgentLaunchPlan) async
  func observe(output: String) async
  func finished() async
  /// The identifier this launch gave its conversation and has not yet seen written down, if any:
  /// asked when the application lets go of a process the terminal host keeps, so that the next
  /// instance can keep watching for it (#141).
  func awaitedResumeIdentifier() async -> String?
  /// Takes up the watch of a process another instance of the application launched and the
  /// terminal host kept: `identifier` is the one it was still waiting for (#141). There is no plan
  /// to read it from, only what that instance wrote down.
  func adopted(awaitedResumeIdentifier identifier: String) async
}

extension AgentLaunchObserver {
  /// A CLI that is not told its identifier has none to wait for: it is discovered or it is not.
  public func awaitedResumeIdentifier() async -> String? { nil }

  public func adopted(awaitedResumeIdentifier identifier: String) async {
    // Nothing was waited for, so there is nothing to take up.
  }
}

/// Implemented by the providers that have something to watch. A provider without it simply has
/// no identifier to keep, which is not a failure.
public protocol AgentLaunchObserverProviding: Sendable {
  func launchObserver(
    for sessionID: SessionID,
    repository: any SessionRepository
  ) -> any AgentLaunchObserver
}
