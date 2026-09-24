import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

@Suite("Codex provider availability")
struct CodexAgentProviderTests {
  private static let path = "/opt/homebrew/bin/codex"

  private func provider(
    location: ExecutableLocation = .found(
      path: CodexAgentProviderTests.path, source: .candidateDirectory),
    probe: StubProcessProbe
  ) -> CodexAgentProvider {
    let environment = ["PATH": "/usr/bin", "HOME": "/Users/test"]
    return CodexAgentProvider(
      base: CommandLineAgentProvider(
        descriptor: CodexAgentProvider.descriptor,
        specification: CodexAgentProvider.specification,
        models: [],
        argumentBuilder: CodexArgumentBuilder(),
        availabilityProbe: AgentAvailabilityProbe(
          descriptor: CodexAgentProvider.descriptor,
          specification: CodexAgentProvider.specification,
          locator: StubLocator(location: location),
          probe: probe,
          environment: environment,
          now: { Date(timeIntervalSince1970: 0) }
        ),
        environment: environment
      ),
      catalog: CodexModelCatalog(cacheURL: URL(fileURLWithPath: "/nonexistent/models_cache.json")),
      discovery: CodexRolloutSessionDiscovery(
        sessionsDirectory: URL(fileURLWithPath: "/nonexistent/sessions"))
    )
  }

  @Test("A signed in installation is available and reports its version")
  func availableInstallation() async {
    let probe = StubProcessProbe(
      defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "codex-cli 0.155.1"))
    )
    let availability = await provider(probe: probe).availability(forceRefresh: false)

    #expect(availability.state == .available)
    #expect(availability.installation?.version == AgentVersion(major: 0, minor: 155, patch: 1))
    // The sign in state comes from an exit code, never from a credential file.
    #expect(probe.invocations.contains { $0.arguments == ["login", "status"] })
  }

  @Test("A failing login status marks the agent unauthenticated but still launchable")
  func unauthenticated() async {
    final class Responder: ProcessProbe, @unchecked Sendable {
      func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        workingDirectoryPath: String?,
        timeout: Duration
      ) async throws -> ProbeResult {
        arguments == ["login", "status"]
          ? ProbeResult(exitCode: 1, standardError: "Not logged in")
          : ProbeResult(exitCode: 0, standardOutput: "codex-cli 0.155.1")
      }
    }

    let environment = ["PATH": "/usr/bin", "HOME": "/Users/test"]
    let provider = CodexAgentProvider(
      base: CommandLineAgentProvider(
        descriptor: CodexAgentProvider.descriptor,
        specification: CodexAgentProvider.specification,
        models: [],
        argumentBuilder: CodexArgumentBuilder(),
        availabilityProbe: AgentAvailabilityProbe(
          descriptor: CodexAgentProvider.descriptor,
          specification: CodexAgentProvider.specification,
          locator: StubLocator(location: .found(path: Self.path, source: .candidateDirectory)),
          probe: Responder(),
          environment: environment,
          now: { Date(timeIntervalSince1970: 0) }
        ),
        environment: environment
      ),
      catalog: CodexModelCatalog(cacheURL: URL(fileURLWithPath: "/nonexistent/models_cache.json")),
      discovery: CodexRolloutSessionDiscovery(
        sessionsDirectory: URL(fileURLWithPath: "/nonexistent/sessions"))
    )

    let availability = await provider.availability(forceRefresh: false)
    #expect(availability.state == .unauthenticated)
    #expect(availability.isUsable)
    #expect(availability.diagnostic.remediations.contains(.authenticate(command: "codex login")))

    // An unproven sign in must not block a launch: the CLI asks for it itself.
    let plan = try? await provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: "/Users/test/app")
    )
    #expect(plan?.arguments == ["-C", "/Users/test/app"])
  }

  @Test("A version below the minimum is reported with an update remediation")
  func outdated() async {
    let probe = StubProcessProbe(
      defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "codex-cli 0.12.0"))
    )
    let availability = await provider(probe: probe).availability(forceRefresh: false)

    #expect(
      availability.state
        == .outdated(
          found: AgentVersion(major: 0, minor: 12), required: CodexAgentProvider.minimumVersion)
    )
    #expect(
      availability.diagnostic.remediations.contains(
        .update(
          minimumVersion: CodexAgentProvider.minimumVersion,
          documentationURL: CodexAgentProvider.specification.documentationURL
        )
      )
    )
    #expect(!availability.isUsable)
  }

  @Test("A missing CLI points at the documentation instead of a bare label")
  func notFound() async {
    let availability = await provider(
      location: .notFound,
      probe: StubProcessProbe()
    ).availability(forceRefresh: false)

    #expect(availability.state == .notFound)
    #expect(
      availability.diagnostic.remediations.contains(
        .install(documentationURL: CodexAgentProvider.specification.documentationURL))
    )
  }

  @Test("A sign in probe that hangs leaves the agent usable rather than blocked")
  func authenticationProbeTimeout() async {
    final class Hanging: ProcessProbe, @unchecked Sendable {
      func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        workingDirectoryPath: String?,
        timeout: Duration
      ) async throws -> ProbeResult {
        arguments == ["login", "status"]
          ? ProbeResult(exitCode: -1, didTimeOut: true)
          : ProbeResult(exitCode: 0, standardOutput: "codex-cli 0.155.1")
      }
    }

    let environment = ["PATH": "/usr/bin", "HOME": "/Users/test"]
    let provider = CommandLineAgentProvider(
      descriptor: CodexAgentProvider.descriptor,
      specification: CodexAgentProvider.specification,
      models: [],
      argumentBuilder: CodexArgumentBuilder(),
      availabilityProbe: AgentAvailabilityProbe(
        descriptor: CodexAgentProvider.descriptor,
        specification: CodexAgentProvider.specification,
        locator: StubLocator(location: .found(path: Self.path, source: .candidateDirectory)),
        probe: Hanging(),
        environment: environment,
        now: { Date(timeIntervalSince1970: 0) }
      ),
      environment: environment
    )

    // An unknown sign in state is not a failed one: the CLI will ask in the terminal.
    let availability = await provider.availability(forceRefresh: false)
    #expect(availability.state == .available)
    #expect(availability.isUsable)
  }

  @Test("An unreadable version keeps the agent usable")
  func unreadableVersion() async {
    let probe = StubProcessProbe(
      defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "codex, the coding agent"))
    )
    let availability = await provider(probe: probe).availability(forceRefresh: false)

    #expect(availability.state == .available)
    #expect(availability.installation?.version == nil)
  }

  @Test("An unavailable CLI refuses to produce a plan")
  func planRequiresAvailability() async {
    let provider = provider(location: .notFound, probe: StubProcessProbe())
    await #expect(throws: AgentLaunchError.self) {
      try await provider.launchPlan(
        for: AgentLaunchRequest(workingDirectoryPath: "/Users/test/app"))
    }
  }

  @Test("The plan carries the detected executable, the directory and an allow listed environment")
  func planShape() async throws {
    let probe = StubProcessProbe(
      defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "codex-cli 0.155.1"))
    )
    let plan = try await provider(probe: probe).launchPlan(
      for: AgentLaunchRequest(
        workingDirectoryPath: "/Users/test/app",
        modelID: "gpt-6-astra",
        initialPrompt: "Bonjour"
      )
    )

    #expect(plan.providerID == CodexAgentProvider.id)
    #expect(plan.executablePath == Self.path)
    #expect(plan.workingDirectoryPath == "/Users/test/app")
    #expect(plan.promptDelivery == .argument)
    #expect(plan.environment["HOME"] == "/Users/test")
    #expect(plan.environment["OPENAI_API_KEY"] == nil)
  }

  @Test("An API key present in the environment is never forwarded to the agent")
  func neverForwardsSecrets() async throws {
    let environment = [
      "PATH": "/usr/bin", "HOME": "/Users/test",
      "OPENAI_API_KEY": "sk-secret", "CODEX_API_KEY": "sk-secret",
    ]
    let probe = StubProcessProbe(
      defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "codex-cli 0.155.1"))
    )
    let provider = CommandLineAgentProvider(
      descriptor: CodexAgentProvider.descriptor,
      specification: CodexAgentProvider.specification,
      models: [],
      argumentBuilder: CodexArgumentBuilder(),
      availabilityProbe: AgentAvailabilityProbe(
        descriptor: CodexAgentProvider.descriptor,
        specification: CodexAgentProvider.specification,
        locator: StubLocator(location: .found(path: Self.path, source: .candidateDirectory)),
        probe: probe,
        environment: environment,
        now: { Date(timeIntervalSince1970: 0) }
      ),
      environment: environment
    )

    let plan = try await provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: "/Users/test/app"))
    #expect(plan.environment["OPENAI_API_KEY"] == nil)
    #expect(plan.environment["CODEX_API_KEY"] == nil)
  }

  @Test("A diagnostic export names no full path and no secret")
  func diagnosticExport() async {
    let probe = StubProcessProbe(
      defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "codex-cli 0.155.1"))
    )
    let availability = await provider(probe: probe).availability(forceRefresh: false)
    let export = availability.diagnostic.exportText()

    #expect(export.contains("Codex"))
    #expect(!export.contains(Self.path))
    #expect(export.contains("/opt/homebrew/bin"))
  }

  @Test("The descriptor advertises what the CLI actually supports")
  func capabilities() {
    let capabilities = CodexAgentProvider.descriptor.capabilities
    #expect(capabilities.supportsModelSelection)
    #expect(capabilities.supportsInitialPrompt)
    #expect(capabilities.supportsResume)
    #expect(capabilities.reportsUsage)
  }
}
