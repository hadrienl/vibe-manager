import Foundation
import VibeApplication
import VibeDomain

/// Keeps the identifier the plan already carries.
///
/// Nothing is read from the terminal: `--session-id` named the conversation before it existed,
/// so the only work left is to store that name once the CLI has actually written the transcript.
public actor ClaudeCodeLaunchObserver: AgentLaunchObserver {
  private let capture: ClaudeCodeSessionIdentifierCapture

  public init(capture: ClaudeCodeSessionIdentifierCapture) {
    self.capture = capture
  }

  public func launched(plan: AgentLaunchPlan) async {
    await capture.record(plan: plan)
  }

  public func observe(output: String) async {}

  public func finished() async {
    await capture.stop()
  }
}

extension ClaudeCodeAgentProvider: AgentLaunchObserverProviding {
  public func launchObserver(
    for sessionID: SessionID,
    repository: any SessionRepository
  ) -> any AgentLaunchObserver {
    ClaudeCodeLaunchObserver(
      capture: identifierCapture(for: sessionID, repository: repository)
    )
  }
}
