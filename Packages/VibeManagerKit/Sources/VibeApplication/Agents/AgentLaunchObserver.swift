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
}

/// Implemented by the providers that have something to watch. A provider without it simply has
/// no identifier to keep, which is not a failure.
public protocol AgentLaunchObserverProviding: Sendable {
  func launchObserver(
    for sessionID: SessionID,
    repository: any SessionRepository
  ) -> any AgentLaunchObserver
}
