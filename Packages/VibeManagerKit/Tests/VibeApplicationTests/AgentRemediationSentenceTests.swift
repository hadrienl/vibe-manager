import Foundation
import Testing
import VibeApplication

@Suite("The sentence shown next to an unusable agent")
struct AgentRemediationSentenceTests {
  @Test("Retrying detection never hides a remedy that says what is wrong")
  func specificRemedyWins() {
    let sentence = AgentRemediation.sentence(for: [
      .retryDetection,
      .update(minimumVersion: AgentVersion(major: 0, minor: 153), documentationURL: nil),
    ])

    #expect(sentence.contains("0.153.0"))
  }

  @Test("A sign-in remedy names the command when the provider published one")
  func authenticationNamesItsCommand() {
    #expect(
      AgentRemediation.sentence(for: [.authenticate(command: "claude auth login")])
        .contains("claude auth login")
    )
    #expect(
      !AgentRemediation.sentence(for: [.authenticate(command: nil)]).contains("Run ")
    )
  }

  @Test("An agent without any published remedy still gets a way forward")
  func emptyRemediationsStillAdvise() {
    #expect(!AgentRemediation.sentence(for: []).isEmpty)
  }

  @Test("Retrying detection alone is still said out loud")
  func retryOnlyIsStated() {
    #expect(AgentRemediation.sentence(for: [.retryDetection]) == "Detect again.")
  }
}
