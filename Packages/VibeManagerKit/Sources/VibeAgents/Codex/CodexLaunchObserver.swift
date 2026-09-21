import Foundation
import VibeApplication
import VibeDomain

/// Watches one Codex launch for the identifier it never announces up front.
///
/// The capture needs the working directory the process was actually started in, which only the
/// plan knows, so it is built when the launch happens rather than when the session is created.
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

  public func launched(plan: AgentLaunchPlan) async {
    let capture = provider.identifierCapture(
      for: sessionID,
      workingDirectoryPath: plan.workingDirectoryPath,
      repository: repository
    )
    self.capture = capture
    await capture.start()
  }

  public func observe(output: String) async {
    await capture?.observe(output: output)
  }

  public func finished() async {
    await capture?.stop()
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
