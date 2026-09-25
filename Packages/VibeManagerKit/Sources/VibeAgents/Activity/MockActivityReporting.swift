import Foundation
import VibeApplication

/// The mock agent reports its activity with the event names of the real hooks, written by the
/// script itself, so the whole chain can be driven without a CLI or an account.
public struct MockSignalDecoder: AgentSignalDecoding {
  public let approvalAnswerKeys: Set<[UInt8]> = [[0x0D], [0x79]]

  public init() {}

  public func signal(for event: AgentActivityEvent) -> AgentSignal? {
    switch event.name {
    case "SessionStart": return .channelConfirmed
    case "UserPromptSubmit": return .promptSubmitted(byUser: true)
    case "PermissionRequest": return .questionAsked(.approval)
    case "AskUserQuestion": return .questionAsked(.question)
    case "PostToolUse": return .questionResolved
    case "Stop": return .turnEnded
    case "Interrupt": return .interrupted
    case "SessionEnd": return .agentEnded
    default: return nil
    }
  }
}

extension MockAgentProvider: AgentActivityReporting {
  public func reportingActivity(_ plan: AgentLaunchPlan, to log: URL) -> AgentLaunchPlan {
    plan.reportingActivity(options: [], to: log)
  }

  public func activityDecoder() -> any AgentSignalDecoding {
    MockSignalDecoder()
  }
}
