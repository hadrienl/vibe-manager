import Testing
import VibeDomain

@testable import VibeUI

/// An agent is named as people know it, never by its identifier while its provider is known
/// (#247): the sidebar, the Agent filter, the inspector, an archived session and VoiceOver.
@Suite("An agent's readable name")
struct AgentNamingTests {
  private let names = ["claude-code": "Claude Code", "codex": "Codex"]

  @Test("A known agent reads by its name, its model after it")
  func known() {
    let agent = SessionAgentConfiguration(providerID: "claude-code", modelID: "sonnet")
    #expect(AgentNaming.name(of: "claude-code", names: names) == "Claude Code")
    #expect(AgentNaming.label(agent, names: names) == "Claude Code · sonnet")
    #expect(
      AgentNaming.label(SessionAgentConfiguration(providerID: "codex"), names: names) == "Codex")
  }

  @Test("An agent no longer detected keeps its identifier: there is no other name for it")
  func unknown() {
    #expect(AgentNaming.name(of: "gone", names: names) == "gone")
  }

  @Test("VoiceOver hears the agent's name, not its identifier")
  func spoken() {
    let session = WorkSession(
      name: "Refactor the supervisor",
      agent: SessionAgentConfiguration(providerID: "claude-code", modelID: "sonnet"))
    let status = SessionStatusPresentation.make(session: session, paneStatus: .running)
    #expect(
      SessionStatusPresentation.accessibilityLabel(for: session, status: status, agentNames: names)
        == "Refactor the supervisor, Claude Code sonnet, Idle")
  }
}
