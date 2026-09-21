import Foundation
import Testing
import VibeApplication

@Suite("Agent diagnostic export")
struct AgentDiagnosticTests {
  private func diagnostic(detail: String? = nil) -> AgentDiagnostic {
    AgentDiagnostic(
      providerID: AgentProviderID("stub"),
      providerName: "Stub Agent",
      state: .available,
      summary: "Stub Agent is ready.",
      detail: detail,
      installation: AgentInstallation(
        executablePath: NSHomeDirectory() + "/.local/bin/stub-agent",
        version: AgentVersion(major: 2, minor: 4, patch: 1),
        rawVersionOutput: "stub-agent 2.4.1",
        source: .candidateDirectory,
        detectedAt: Date(timeIntervalSince1970: 0)
      ),
      probedAt: Date(timeIntervalSince1970: 0),
      remediations: [.retryDetection]
    )
  }

  @Test("The export shows the detection source, the directory and the version")
  func exportsUsefulContext() {
    let text = diagnostic().exportText()

    #expect(text.contains("candidateDirectory"))
    #expect(text.contains("2.4.1"))
    #expect(text.contains("stub-agent"))
  }

  @Test("The export never leaks the home directory of the user")
  func redactsHomeDirectory() {
    let text = diagnostic().exportText()

    #expect(text.contains("~/.local/bin"))
    #expect(!text.contains(NSHomeDirectory()))
  }

  @Test("The environment allow list drops everything it was not told to keep")
  func environmentAllowList() {
    let environment = AgentEnvironmentPolicy.environment(
      base: [
        "PATH": "/usr/bin",
        "HOME": "/Users/test",
        "ANTHROPIC_API_KEY": "sk-secret",
        "AWS_SESSION_TOKEN": "token",
      ],
      additionalKeys: ["STUB_AGENT_HOME"],
      overrides: ["STUB_AGENT_HOME": "/Users/test/.stub"]
    )

    #expect(environment["PATH"] == "/usr/bin")
    #expect(environment["STUB_AGENT_HOME"] == "/Users/test/.stub")
    #expect(environment["ANTHROPIC_API_KEY"] == nil)
    #expect(environment["AWS_SESSION_TOKEN"] == nil)
  }

  @Test("Only usable states allow a launch")
  func usableStates() {
    #expect(AgentAvailabilityState.available.isUsable)
    // An unproven sign in is not a reason to refuse: the CLI itself will prompt.
    #expect(AgentAvailabilityState.unauthenticated.isUsable)
    #expect(!AgentAvailabilityState.notFound.isUsable)
    #expect(!AgentAvailabilityState.notExecutable.isUsable)
    #expect(!AgentAvailabilityState.probeFailed(reason: .timedOut).isUsable)
    #expect(
      !AgentAvailabilityState.outdated(
        found: AgentVersion(major: 1),
        required: AgentVersion(major: 2)
      ).isUsable
    )
  }
}
