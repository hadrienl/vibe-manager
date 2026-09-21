import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

private final class ScriptedClaudeProbe: ProcessProbe, @unchecked Sendable {
  private let versionResult: ProbeResult
  private let authenticationResult: ProbeResult
  private let lock = NSLock()
  private var recorded: [[String]] = []

  init(version: ProbeResult, authentication: ProbeResult) {
    versionResult = version
    authenticationResult = authentication
  }

  var invocations: [[String]] {
    lock.withLock { recorded }
  }

  func run(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    workingDirectoryPath: String?,
    timeout: Duration
  ) async throws -> ProbeResult {
    lock.withLock { recorded.append(arguments) }
    return arguments == ["--version"] ? versionResult : authenticationResult
  }
}

@Suite("Claude Code provider availability")
struct ClaudeCodeAgentProviderTests {
  private static let path = "/opt/homebrew/bin/claude"
  private static let signedIn = ProbeResult(
    exitCode: 0,
    standardOutput: #"{"loggedIn":true,"email":"a@b.c","orgName":"Org","subscriptionType":"max"}"#
  )

  private func provider(
    location: ExecutableLocation = .found(
      path: ClaudeCodeAgentProviderTests.path, source: .candidateDirectory),
    probe: any ProcessProbe
  ) -> ClaudeCodeAgentProvider {
    let environment = ["PATH": "/usr/bin", "HOME": "/Users/test"]
    return ClaudeCodeAgentProvider(
      base: CommandLineAgentProvider(
        descriptor: ClaudeCodeAgentProvider.descriptor,
        specification: ClaudeCodeAgentProvider.specification,
        models: [],
        argumentBuilder: ClaudeCodeArgumentBuilder(),
        availabilityProbe: AgentAvailabilityProbe(
          descriptor: ClaudeCodeAgentProvider.descriptor,
          specification: ClaudeCodeAgentProvider.specification,
          locator: StubLocator(location: location),
          probe: probe,
          environment: environment,
          now: { Date(timeIntervalSince1970: 0) }
        ),
        environment: environment
      ),
      catalog: ClaudeCodeModelCatalog(
        directory: URL(fileURLWithPath: "/nonexistent/model-catalog"))
    )
  }

  @Test("A signed in installation is available and reports its version")
  func availableInstallation() async {
    let probe = ScriptedClaudeProbe(
      version: ProbeResult(exitCode: 0, standardOutput: "2.1.278 (Claude Code)"),
      authentication: Self.signedIn
    )
    let availability = await provider(probe: probe).availability(forceRefresh: false)

    #expect(availability.state == .available)
    #expect(availability.installation?.version == AgentVersion(major: 2, minor: 1, patch: 278))
    #expect(probe.invocations.contains(["auth", "status", "--json"]))
  }

  @Test("A signed out account is unauthenticated, launchable, and told how to sign in")
  func unauthenticated() async {
    let probe = ScriptedClaudeProbe(
      version: ProbeResult(exitCode: 0, standardOutput: "2.1.278 (Claude Code)"),
      authentication: ProbeResult(exitCode: 0, standardOutput: #"{"loggedIn":false}"#)
    )
    let provider = provider(probe: probe)

    let availability = await provider.availability(forceRefresh: false)
    #expect(availability.state == .unauthenticated)
    // The CLI asks for the sign in itself, in the terminal, where the user can answer.
    #expect(availability.isUsable)
    #expect(
      availability.diagnostic.remediations.contains(.authenticate(command: "claude auth login")))

    let plan = try? await provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: "/Users/test/app")
    )
    #expect(plan?.arguments.first == "--session-id")
  }

  @Test("An unreadable authentication answer never blocks a launch")
  func unknownAuthenticationState() async {
    let probe = ScriptedClaudeProbe(
      version: ProbeResult(exitCode: 0, standardOutput: "2.1.278 (Claude Code)"),
      authentication: ProbeResult(exitCode: 0, standardOutput: "who knows")
    )
    let availability = await provider(probe: probe).availability(forceRefresh: false)

    #expect(availability.state == .available)
  }

  @Test("A version below the minimum is reported with an update remediation")
  func outdated() async {
    let probe = ScriptedClaudeProbe(
      version: ProbeResult(exitCode: 0, standardOutput: "2.0.42 (Claude Code)"),
      authentication: Self.signedIn
    )
    let availability = await provider(probe: probe).availability(forceRefresh: false)

    #expect(
      availability.state
        == .outdated(
          found: AgentVersion(major: 2, minor: 0, patch: 42),
          required: ClaudeCodeAgentProvider.minimumVersion
        )
    )
    #expect(
      availability.diagnostic.remediations.contains(
        .update(
          minimumVersion: ClaudeCodeAgentProvider.minimumVersion,
          documentationURL: ClaudeCodeAgentProvider.specification.documentationURL
        )
      )
    )
  }

  @Test("A missing CLI cannot produce a launch plan")
  func notFound() async {
    let probe = ScriptedClaudeProbe(
      version: ProbeResult(exitCode: 0), authentication: Self.signedIn)
    let provider = provider(location: .notFound, probe: probe)

    #expect(await provider.availability(forceRefresh: false).state == .notFound)
    await #expect(throws: AgentLaunchError.unavailable(.notFound)) {
      try await provider.launchPlan(
        for: AgentLaunchRequest(workingDirectoryPath: "/Users/test/app"))
    }
  }

  @Test("The plan runs in the session directory and carries only allowed environment keys")
  func planEnvironment() async throws {
    let probe = ScriptedClaudeProbe(
      version: ProbeResult(exitCode: 0, standardOutput: "2.1.278 (Claude Code)"),
      authentication: Self.signedIn
    )
    let plan = try await provider(probe: probe).launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: "/Users/test/app")
    )

    // The CLI has no directory option: the working directory is the whole contract.
    #expect(plan.workingDirectoryPath == "/Users/test/app")
    #expect(!plan.arguments.contains("-C"))
    #expect(!plan.arguments.contains("--add-dir"))
    #expect(plan.environment["PATH"] == "/usr/bin")
    #expect(plan.environment["ANTHROPIC_API_KEY"] == nil)
    #expect(plan.promptDelivery == .none)
  }

  @Test("No flag lowers a guard rail or moves the session off this Mac")
  func neverLowersSafety() async throws {
    let probe = ScriptedClaudeProbe(
      version: ProbeResult(exitCode: 0, standardOutput: "2.1.278 (Claude Code)"),
      authentication: Self.signedIn
    )
    let plan = try await provider(probe: probe).launchPlan(
      for: AgentLaunchRequest(
        workingDirectoryPath: "/Users/test/app",
        modelID: "claude-opus-5",
        initialPrompt: "Hello"
      )
    )

    let forbidden = [
      "-p", "--print", "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
      "--permission-mode", "--tools", "--allowedTools", "--disallowedTools", "--settings",
      "--mcp-config", "--bare", "--safe-mode", "--bg", "--background", "--cloud", "--teleport",
      "--remote-control", "--worktree", "--tmux", "--ide", "--chrome", "--continue", "-c",
    ]
    #expect(!plan.arguments.contains { forbidden.contains($0) })
  }

  @Test("An API key in the application environment never reaches the agent")
  func neverForwardsSecrets() async throws {
    let environment = [
      "PATH": "/usr/bin", "HOME": "/Users/test",
      "ANTHROPIC_API_KEY": "sk-secret", "ANTHROPIC_AUTH_TOKEN": "token",
      "CLAUDE_CODE_OAUTH_TOKEN": "oauth", "CLAUDE_CONFIG_DIR": "~/elsewhere",
    ]
    let probe = ScriptedClaudeProbe(
      version: ProbeResult(exitCode: 0, standardOutput: "2.1.278 (Claude Code)"),
      authentication: Self.signedIn
    )
    let sanitized = ClaudeCodeHome.sanitized(environment: environment)
    let provider = ClaudeCodeAgentProvider(
      base: CommandLineAgentProvider(
        descriptor: ClaudeCodeAgentProvider.descriptor,
        specification: ClaudeCodeAgentProvider.specification,
        models: [],
        argumentBuilder: ClaudeCodeArgumentBuilder(),
        availabilityProbe: AgentAvailabilityProbe(
          descriptor: ClaudeCodeAgentProvider.descriptor,
          specification: ClaudeCodeAgentProvider.specification,
          locator: StubLocator(location: .found(path: Self.path, source: .candidateDirectory)),
          probe: probe,
          environment: sanitized,
          now: { Date(timeIntervalSince1970: 0) }
        ),
        environment: sanitized
      ),
      catalog: ClaudeCodeModelCatalog(directory: URL(fileURLWithPath: "/nonexistent"))
    )

    let plan = try await provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: "/Users/test/app"))

    #expect(plan.environment["ANTHROPIC_API_KEY"] == nil)
    #expect(plan.environment["ANTHROPIC_AUTH_TOKEN"] == nil)
    #expect(plan.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    // The configuration directory is forwarded, but only once it is an absolute path.
    #expect(plan.environment["CLAUDE_CONFIG_DIR"] == "/Users/test/elsewhere")
  }

  @Test("An exported diagnostic carries no identity")
  func diagnosticCarriesNoIdentity() async {
    let probe = ScriptedClaudeProbe(
      version: ProbeResult(exitCode: 0, standardOutput: "2.1.278 (Claude Code)"),
      authentication: Self.signedIn
    )
    let text = await provider(probe: probe).availability(forceRefresh: false)
      .diagnostic.exportText()

    for secret in ["a@b.c", "Org", "max", "loggedIn"] {
      #expect(!text.contains(secret))
    }
  }
}

@Suite("Claude Code authentication status")
struct ClaudeCodeAuthenticationStatusTests {
  @Test("Only the sign in flag is read out of the answer")
  func readsOnlyTheFlag() {
    let signedIn = ProbeResult(
      exitCode: 0,
      standardOutput: #"{"loggedIn":true,"email":"a@b.c","orgId":"7c7","subscriptionType":"max"}"#
    )
    #expect(ClaudeCodeAuthenticationStatus.isSignedIn(in: signedIn) == true)
    #expect(
      ClaudeCodeAuthenticationStatus.isSignedIn(
        in: ProbeResult(exitCode: 0, standardOutput: #"{"loggedIn":false}"#)) == false
    )
  }

  @Test("An unreadable or empty answer is unknown, not a refusal")
  func unknownStates() {
    #expect(ClaudeCodeAuthenticationStatus.isSignedIn(in: ProbeResult(exitCode: 0)) == nil)
    #expect(
      ClaudeCodeAuthenticationStatus.isSignedIn(
        in: ProbeResult(exitCode: 0, standardOutput: "not json")) == nil
    )
  }

  @Test("A failing command without a readable answer counts as signed out")
  func failingCommand() {
    #expect(
      ClaudeCodeAuthenticationStatus.isSignedIn(
        in: ProbeResult(exitCode: 1, standardError: "Not logged in")) == false
    )
  }

  @Test("Warnings around the answer do not hide it")
  func readsThroughNoise() {
    #expect(
      ClaudeCodeAuthenticationStatus.isSignedIn(
        in: ProbeResult(
          exitCode: 1,
          standardOutput: """
            (node:4242) [DEP0040] DeprecationWarning: punycode is deprecated
            {"loggedIn":true}
            """)) == true
    )
    #expect(
      ClaudeCodeAuthenticationStatus.isSignedIn(
        in: ProbeResult(
          exitCode: 0,
          standardOutput: #"warning: proxy in use {"loggedIn":false} done"#)) == false
    )
  }

  @Test("Standard error is read only when standard output says nothing")
  func fallsBackToStandardError() {
    #expect(
      ClaudeCodeAuthenticationStatus.isSignedIn(
        in: ProbeResult(exitCode: 0, standardError: #"{"loggedIn":true}"#)) == true
    )
  }
}
