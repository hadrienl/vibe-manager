import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// An agent that cannot run says what to do, and the agent row lets it be done (#234).
@Suite("The remedy of an agent, as something to do")
struct AgentRemedyActionTests {
  private static let page = URL(string: "https://example.com/install")!

  private func option(
    _ state: AgentAvailabilityState, remediations: [AgentRemediation]
  ) -> AgentOption {
    let diagnostic = AgentDiagnostic(
      providerID: AgentProviderID("claude-code"), providerName: "Claude Code", state: state,
      summary: "", probedAt: Date(timeIntervalSince1970: 0), remediations: remediations)
    return AgentOption(
      descriptor: AgentDescriptor(id: AgentProviderID("claude-code"), displayName: "Claude Code"),
      availability: AgentAvailability(state: state, installation: nil, diagnostic: diagnostic))
  }

  @Test("A missing agent links to its install page")
  func missingLinksToInstall() {
    let agent = option(
      .notFound, remediations: [.install(documentationURL: Self.page), .retryDetection])

    #expect(agent.installationPage == Self.page)
    #expect(!agent.installationPageUpdates)
    #expect(agent.signInCommand == nil)
  }

  @Test("An outdated agent links to the page that updates it")
  func outdatedLinksToUpdate() {
    let required = AgentVersion(major: 2)
    let agent = option(
      .outdated(found: AgentVersion(major: 1), required: required),
      remediations: [.update(minimumVersion: required, documentationURL: Self.page)])

    #expect(agent.installationPage == Self.page)
    #expect(agent.installationPageUpdates)
  }

  @Test("An agent waiting for sign-in offers its command to copy")
  func unauthenticatedOffersItsCommand() {
    let agent = option(
      .unauthenticated,
      remediations: [.authenticate(command: "claude auth login"), .retryDetection])

    #expect(agent.signInCommand == "claude auth login")
    #expect(agent.installationPage == nil)
  }

  @Test("An agent that runs offers nothing to do")
  func availableOffersNothing() {
    let agent = option(.available, remediations: [.retryDetection])

    #expect(agent.installationPage == nil)
    #expect(agent.signInCommand == nil)
  }
}
