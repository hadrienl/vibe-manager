import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

@Suite("Launch plan construction")
struct AgentLaunchPlanTests {
  private let provider = TestFixtures.provider(
    locator: StubLocator(
      location: .found(path: "/opt/homebrew/bin/stub-agent", source: .candidateDirectory)
    ),
    probe: StubProcessProbe(
      defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 2.4.1"))
    )
  )

  private func plan(
    workingDirectoryPath: String = "/Users/test/Projects/app",
    modelID: String? = nil,
    initialPrompt: String? = nil,
    resume: AgentResumeRequest = .none,
    additionalEnvironment: [String: String] = [:]
  ) throws -> AgentLaunchPlan {
    try provider.plan(
      for: AgentLaunchRequest(
        workingDirectoryPath: workingDirectoryPath,
        modelID: modelID,
        initialPrompt: initialPrompt,
        resume: resume,
        additionalEnvironment: additionalEnvironment
      ),
      installation: TestFixtures.installation
    )
  }

  @Test("A plain launch produces the expected command")
  func buildsMinimalPlan() throws {
    let plan = try plan()

    #expect(plan.executablePath == "/opt/homebrew/bin/stub-agent")
    #expect(plan.arguments.isEmpty)
    #expect(plan.workingDirectoryPath == "/Users/test/Projects/app")
    #expect(plan.promptDelivery == .none)
    #expect(plan.version == AgentVersion(major: 2, minor: 1, patch: 0))
  }

  @Test("Model, resume and prompt are passed as separate arguments")
  func buildsFullPlan() throws {
    let plan = try plan(modelID: "deep", initialPrompt: "Refactor", resume: .identifier("abc-123"))

    #expect(
      plan.arguments == ["--model", "deep", "--resume", "abc-123", "--prompt", "Refactor"]
    )
    #expect(plan.promptDelivery == .argument)
  }

  @Test(
    "Prompts that would break a shell stay intact as a single argument",
    arguments: [
      "rm -rf / ; echo pwned",
      "a prompt with \"double\" and 'single' quotes",
      "$(whoami) and `hostname` and $HOME",
      "multi\nline\tprompt",
      "accents éàü and emoji 🤖 and 中文",
      "back\\slash and | pipe && chain",
    ]
  )
  func keepsDifficultPromptsIntact(prompt: String) throws {
    let plan = try plan(initialPrompt: prompt)

    // Arguments are handed to the process as an array: no quoting, no escaping, no shell.
    #expect(plan.arguments.last == prompt)
    #expect(plan.arguments.count == 2)
  }

  @Test("Working directories with spaces and non ASCII characters are preserved")
  func keepsDifficultWorkingDirectories() throws {
    let path = "/Users/test/Mes Projets/été 2026"
    #expect(try plan(workingDirectoryPath: path).workingDirectoryPath == path)
  }

  @Test("A large prompt moves to the standard input")
  func largePromptUsesStandardInput() throws {
    let prompt = String(repeating: "a", count: AgentPromptLimits.argumentByteLimit + 1)
    let plan = try plan(initialPrompt: prompt)

    #expect(plan.promptDelivery == .standardInput(prompt))
    #expect(plan.arguments == ["--prompt-from-stdin"])
    #expect(!plan.arguments.contains(prompt))
  }

  @Test("A prompt holding a NUL is refused rather than sent cut short")
  func refusesNullCharacter() {
    #expect(throws: AgentLaunchError.promptContainsNullCharacter) {
      try plan(initialPrompt: "Review this\u{0} and not that")
    }
  }

  @Test("A prompt above the hard limit is refused")
  func refusesOversizedPrompt() {
    let prompt = String(repeating: "a", count: AgentPromptLimits.maximumByteLimit + 1)

    #expect(throws: AgentLaunchError.self) {
      try plan(initialPrompt: prompt)
    }
  }

  @Test("An unknown model is refused instead of being forwarded")
  func refusesUnknownModel() {
    #expect(throws: AgentLaunchError.unsupportedModel("gpt-imaginary")) {
      try plan(modelID: "gpt-imaginary")
    }
  }

  @Test("A relative working directory is refused")
  func refusesRelativeWorkingDirectory() {
    #expect(throws: AgentLaunchError.invalidWorkingDirectory) {
      try plan(workingDirectoryPath: "Projects/app")
    }
  }

  @Test("An empty resume identifier is refused")
  func refusesEmptyResumeIdentifier() {
    #expect(throws: AgentLaunchError.missingResumeIdentifier) {
      try plan(resume: .identifier("   "))
    }
  }

  @Test("A provider without resume support refuses a resume request")
  func refusesUnsupportedResume() {
    let descriptor = AgentDescriptor(
      id: AgentProviderID("stub"),
      displayName: "Stub Agent",
      capabilities: AgentCapabilities(supportsInitialPrompt: true)
    )

    #expect(throws: AgentLaunchError.resumeUnsupported) {
      try AgentLaunchValidation.validateResume(.identifier("abc"), descriptor: descriptor)
    }
  }

  @Test("The environment is an allow list, so injected secrets never reach the agent")
  func environmentIsAllowListed() throws {
    let provider = TestFixtures.provider(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
      ),
      probe: StubProcessProbe(),
      environment: [
        "PATH": "/usr/bin",
        "HOME": "/Users/test",
        "AWS_SECRET_ACCESS_KEY": "super-secret",
        "ANTHROPIC_API_KEY": "sk-should-not-leak",
      ]
    )

    let plan = try provider.plan(
      for: AgentLaunchRequest(workingDirectoryPath: "/Users/test/app"),
      installation: TestFixtures.installation
    )

    #expect(plan.environment["PATH"] == "/usr/bin")
    #expect(plan.environment["AWS_SECRET_ACCESS_KEY"] == nil)
    #expect(plan.environment["ANTHROPIC_API_KEY"] == nil)
  }

  @Test("The shell's PATH replaces the inherited one, and the request still has the last word")
  func shellEnvironmentWins() throws {
    let plan = try provider.plan(
      for: AgentLaunchRequest(
        workingDirectoryPath: "/Users/test/app", additionalEnvironment: ["NVM_DIR": "/request"]),
      installation: TestFixtures.installation,
      shellEnvironment: ["PATH": "/Users/test/.local/bin:/usr/bin", "NVM_DIR": "/Users/test/.nvm"]
    )

    #expect(plan.environment["PATH"] == "/Users/test/.local/bin:/usr/bin")
    #expect(plan.environment["NVM_DIR"] == "/request")
    #expect(plan.environment["HOME"] == "/Users/test")
  }

  @Test("A launch asks the shell for its environment")
  func launchUsesTheShellEnvironment() async throws {
    let probe = StubProcessProbe(
      defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 2.4.1")))
    let shell = LoginShellEnvironment(
      inherited: [:],
      probe: StubProcessProbe(
        defaultResponse: .success(
          ProbeResult(
            exitCode: 0,
            standardOutput: LoginShellEnvironment.marker + "PATH=/Users/test/.local/bin"))))
    let provider = TestFixtures.provider(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .candidateDirectory)),
      probe: probe,
      shellEnvironment: shell
    )

    let plan = try await provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: "/Users/test/app"))

    #expect(plan.environment["PATH"] == "/Users/test/.local/bin")
  }

  @Test("A shell that does not answer leaves the inherited PATH")
  func silentShellKeepsTheInheritedPath() async throws {
    let provider = TestFixtures.provider(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .candidateDirectory)),
      probe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 2.4.1"))),
      shellEnvironment: LoginShellEnvironment(
        inherited: [:],
        probe: StubProcessProbe(
          defaultResponse: .success(ProbeResult(exitCode: -1, didTimeOut: true))))
    )

    let plan = try await provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: "/Users/test/app"))

    #expect(plan.environment["PATH"] == "/usr/bin")
  }

  @Test("Explicit overrides are the only way to add an environment variable")
  func overridesAreExplicit() throws {
    let plan = try plan(additionalEnvironment: ["STUB_AGENT_MODE": "test"])

    #expect(plan.environment["STUB_AGENT_MODE"] == "test")
  }

  @Test("The same request always produces the same plan")
  func planIsDeterministic() throws {
    let first = try plan(modelID: "fast", initialPrompt: "Hello", resume: .identifier("id"))
    let second = try plan(modelID: "fast", initialPrompt: "Hello", resume: .identifier("id"))

    #expect(first == second)
  }

  @Test("An unavailable provider refuses to build a plan")
  func refusesWhenUnavailable() async {
    let provider = TestFixtures.provider(
      locator: StubLocator(location: .notFound),
      probe: StubProcessProbe()
    )

    await #expect(throws: AgentLaunchError.unavailable(.notFound)) {
      try await provider.launchPlan(
        for: AgentLaunchRequest(workingDirectoryPath: "/Users/test/app")
      )
    }
  }
}
