import Foundation
import VibeApplication
import VibeDomain

/// Watches one Codex launch for the identifier it never announces up front.
///
/// The capture needs the working directory the process was actually started in, which only the
/// plan knows, so it is built when the launch happens rather than when the session is created.
///
/// Codex names its session only with the first message (#144). A launch whose hooks are approved
/// hears the name from the agent itself, through `conversationNamed`, and looks for the rollout
/// only for the usual half minute. A launch without hooks, or with hooks Codex may still refuse to
/// run, relies on the rollout: it is looked for as long as the process lives.
public actor CodexLaunchObserver: AgentLaunchObserver {
  private let sessionID: SessionID
  private let repository: any SessionRepository
  private let provider: CodexAgentProvider
  private var capture: CodexSessionIdentifierCapture?

  public init(
    sessionID: SessionID,
    repository: any SessionRepository,
    provider: CodexAgentProvider
  ) {
    self.sessionID = sessionID
    self.repository = repository
    self.provider = provider
  }

  /// A launch nobody said had approved hooks: the rollout is its only sure source.
  public func launched(plan: AgentLaunchPlan) async {
    await launched(plan: plan, hooksApproved: false)
  }

  /// The half minute is kept only for hooks known to run. Hooks the plan carries but whose
  /// approval is unknown, or did not take, may still be refused in the terminal (#144).
  public func launched(plan: AgentLaunchPlan, hooksApproved: Bool) async {
    let reportsThroughHooks =
      hooksApproved && plan.environment[AgentActivityHookCommand.environmentKey] != nil
    let capture = provider.identifierCapture(
      for: sessionID,
      workingDirectoryPath: plan.workingDirectoryPath,
      repository: repository,
      timeout: reportsThroughHooks
        ? CodexSessionIdentifierCapture.defaultTimeout
        : CodexSessionIdentifierCapture.defaultWatchLimit
    )
    self.capture = capture
    // A resumed conversation already has its rollout, and its identifier on the session: a new
    // rollout in the same folder would be another launch's.
    guard CodexArgumentBuilder.resumedIdentifier(in: plan.arguments) == nil else { return }
    await capture.start()
  }

  public func observe(output: String) async -> AgentOutputDemand {
    guard let capture else { return .more }
    return await capture.observe(output: output)
  }

  public func finished() async {
    await capture?.finish()
  }

  public func conversationNamed(_ identifier: String) async {
    await namingCapture().named(identifier)
  }

  public func awaitedResumeIdentifier() async -> String? {
    await capture?.awaitedIdentifier
  }

  /// What the previous instance had heard the agent name but not yet written.
  public func adopted(awaitedResumeIdentifier identifier: String) async {
    await namingCapture().named(identifier)
  }

  /// The capture of the launch, or — for a process adopted from the terminal host, whose plan
  /// stayed with the previous instance — one that only listens to the agent's own hooks.
  private func namingCapture() -> CodexSessionIdentifierCapture {
    if let capture { return capture }
    let capture = provider.identifierCapture(
      for: sessionID, workingDirectoryPath: "", repository: repository)
    self.capture = capture
    return capture
  }
}

extension CodexAgentProvider: AgentLaunchObserverProviding {
  public func launchObserver(
    for sessionID: SessionID,
    repository: any SessionRepository
  ) -> any AgentLaunchObserver {
    CodexLaunchObserver(sessionID: sessionID, repository: repository, provider: self)
  }
}
