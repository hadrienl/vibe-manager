import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

@Suite("Mock agent provider")
struct MockAgentProviderTests {
  private let provider = MockAgentProvider(environment: ["PATH": "/usr/bin", "HOME": "/Users/test"])

  @Test("The bundled script is found and reported as available")
  func isAvailableOutOfTheBox() async {
    let availability = await provider.availability(forceRefresh: false)

    #expect(availability.state == .available)
    #expect(availability.installation?.executablePath.hasSuffix("mock-agent.sh") == true)
    #expect(availability.installation?.version == AgentVersion(major: 1, minor: 0, patch: 0))
  }

  @Test("It builds a runnable plan with prompt, model and resume")
  func buildsPlan() async throws {
    let plan = try await provider.launchPlan(
      for: AgentLaunchRequest(
        workingDirectoryPath: "/Users/test/app",
        modelID: "mock-deep",
        initialPrompt: "Say hello",
        resume: .identifier("session-42")
      )
    )

    #expect(plan.executablePath == "/bin/sh")
    #expect(plan.arguments.contains("--model"))
    #expect(plan.arguments.contains("mock-deep"))
    #expect(plan.arguments.contains("session-42"))
    #expect(plan.arguments.last == "Say hello")
  }

  @Test("Every availability state can be simulated without touching the file system")
  func simulatesStates() async {
    let states: [AgentAvailabilityState] = [
      .notFound, .notExecutable, .unauthenticated,
      .outdated(found: AgentVersion(major: 0, minor: 9), required: AgentVersion(major: 1)),
      .probeFailed(reason: .timedOut),
    ]

    for state in states {
      let availability = await MockAgentProvider(simulatedState: state).availability()
      #expect(availability.state == state)
      #expect(!availability.diagnostic.remediations.isEmpty)
    }
  }

  @Test("A simulated missing agent refuses to build a plan")
  func refusesPlanWhenSimulatedMissing() async {
    let provider = MockAgentProvider(simulatedState: .notFound)

    await #expect(throws: AgentLaunchError.unavailable(.notFound)) {
      try await provider.launchPlan(
        for: AgentLaunchRequest(workingDirectoryPath: "/Users/test/app")
      )
    }
  }

  @Test("The resume identifier printed by the agent is extracted")
  func extractsResumeIdentifier() {
    let extractor = MockResumeIdentifierExtractor()

    #expect(extractor.resumeIdentifier(in: "mock-session-id: abc-123\nStarting") == "abc-123")
    #expect(extractor.resumeIdentifier(in: "no identifier here") == nil)
    #expect(extractor.resumeIdentifier(in: "mock-session-id: ") == nil)
  }

  @Test("Running the bundled script actually produces a session")
  func scriptRunsEndToEnd() async throws {
    let plan = try await provider.launchPlan(
      for: AgentLaunchRequest(
        workingDirectoryPath: NSTemporaryDirectory(),
        modelID: "mock-fast",
        initialPrompt: "hello \"world\" ; echo pwned"
      )
    )

    let result = try await SystemProcessProbe().run(
      executablePath: plan.executablePath,
      arguments: plan.arguments,
      environment: plan.environment,
      workingDirectoryPath: plan.workingDirectoryPath,
      timeout: .seconds(10)
    )

    #expect(result.exitCode == 0)
    #expect(MockResumeIdentifierExtractor().resumeIdentifier(in: result.standardOutput) != nil)
    #expect(result.standardOutput.contains("model: mock-fast"))
    // The prompt reached the agent verbatim and no shell interpreted it.
    #expect(result.standardOutput.contains("prompt: hello \"world\" ; echo pwned"))
    #expect(!result.standardOutput.split(separator: "\n").contains("pwned"))
  }
}
