import VibeDomain

/// What watches one launch long enough to keep what makes it resumable.
///
/// The two CLIs reveal their session identifier in ways that have nothing in common — one is
/// told which identifier to use, the other has to be discovered — so the knowledge stays inside
/// each provider and only this shape crosses into the application.
public protocol AgentLaunchObserver: Sendable {
  func launched(plan: AgentLaunchPlan) async
  /// The same, knowing whether the CLI will really run the hooks the plan carries: approved, or
  /// not needing an approval (#144). A plan whose hooks may still be refused in the terminal is
  /// launched with `false`.
  func launched(plan: AgentLaunchPlan, hooksApproved: Bool) async
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
  /// The agent named its conversation itself, through the hooks of this very process (#144): the
  /// one report that cannot belong to another launch. Given to the observer of a launch, and to
  /// the observer of a process adopted from the terminal host.
  func conversationNamed(_ identifier: String) async
}

extension AgentLaunchObserver {
  public func launched(plan: AgentLaunchPlan, hooksApproved: Bool) async {
    await launched(plan: plan)
  }

  /// A CLI that is not told its identifier has none to wait for: it is discovered or it is not.
  public func awaitedResumeIdentifier() async -> String? { nil }

  public func adopted(awaitedResumeIdentifier identifier: String) async {
    // Nothing was waited for, so there is nothing to take up.
  }

  public func conversationNamed(_ identifier: String) async {
    // A CLI told its identifier up front has nothing to learn from the report.
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
