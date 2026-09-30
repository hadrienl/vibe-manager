import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

/// A gateway that records what it is told and starts nothing.
private actor RecordingGateway: EndpointGatewayControlling {
  var registered: [(token: String, endpoint: EndpointID, model: String, session: SessionID?)] = []
  var started = 0
  var failure: EndpointGatewayError?

  func fail(with failure: EndpointGatewayError) { self.failure = failure }

  func ensureRunning() throws -> URL {
    if let failure { throw failure }
    started += 1
    return URL(string: "http://127.0.0.1:61234") ?? URL(fileURLWithPath: "/")
  }

  func register(token: String, endpoint: EndpointID, model: String, session: SessionID?) {
    registered.append((token, endpoint, model, session))
  }

  func retain(sessions: Set<SessionID>) {}
}

/// Claude Code installed and answering its version, but signed out.
private struct SignedOutClaudeProbe: ProcessProbe {
  func run(
    executablePath: String, arguments: [String], environment: [String: String],
    workingDirectoryPath: String?, timeout: Duration
  ) async throws -> ProbeResult {
    arguments == ["--version"]
      ? ProbeResult(exitCode: 0, standardOutput: "2.1.285 (Claude Code)")
      : ProbeResult(exitCode: 1, standardOutput: #"{"loggedIn":false}"#)
  }
}

@Suite("An endpoint as an agent")
struct EndpointAgentProviderTests {
  private static let environment = ["PATH": "/usr/bin", "HOME": "/Users/test"]

  private static func claude() -> ClaudeCodeAgentProvider {
    ClaudeCodeAgentProvider(
      base: CommandLineAgentProvider(
        descriptor: ClaudeCodeAgentProvider.descriptor,
        specification: ClaudeCodeAgentProvider.specification,
        models: [],
        argumentBuilder: ClaudeCodeArgumentBuilder(),
        availabilityProbe: AgentAvailabilityProbe(
          descriptor: ClaudeCodeAgentProvider.descriptor,
          specification: ClaudeCodeAgentProvider.specification,
          locator: StubLocator(
            location: .found(path: "/opt/homebrew/bin/claude", source: .candidateDirectory)),
          probe: SignedOutClaudeProbe(),
          environment: environment,
          now: { Date(timeIntervalSince1970: 0) }),
        environment: environment),
      catalog: ClaudeCodeModelCatalog(directory: URL(fileURLWithPath: "/nonexistent/catalog")))
  }

  private static func codex(found: Bool = true) -> CodexAgentProvider {
    CodexAgentProvider(
      base: CommandLineAgentProvider(
        descriptor: CodexAgentProvider.descriptor,
        specification: CodexAgentProvider.specification,
        models: [],
        argumentBuilder: CodexArgumentBuilder(),
        availabilityProbe: AgentAvailabilityProbe(
          descriptor: CodexAgentProvider.descriptor,
          specification: CodexAgentProvider.specification,
          locator: StubLocator(
            location: found
              ? .found(path: "/opt/homebrew/bin/codex", source: .candidateDirectory) : .notFound),
          probe: StubProcessProbe(),
          environment: environment,
          now: { Date(timeIntervalSince1970: 0) }),
        environment: environment),
      catalog: CodexModelCatalog(cacheURL: URL(fileURLWithPath: "/nonexistent/models_cache.json")),
      discovery: CodexRolloutSessionDiscovery(
        sessionsDirectory: URL(fileURLWithPath: "/nonexistent/sessions")))
  }

  private static func endpoint(
    wire: EndpointWireKind = .chatCompletions, harness: EndpointHarnessChoice = .automatic,
    authentication: EndpointAuthenticationKind = .bearer,
    models: [EndpointModel] = [
      EndpointModel(id: "qwen3-coder:30b", contextWindow: 65_536),
      EndpointModel(id: "llama3.2:3b", supportsTools: false),
    ]
  ) -> Endpoint {
    Endpoint(
      name: "Ollama", baseURL: "http://localhost:11434", wireProtocol: wire,
      authentication: authentication, harness: harness, models: models)
  }

  private func provider(
    _ endpoint: Endpoint, gateway: any EndpointGatewayControlling = RecordingGateway(),
    secrets: InMemoryEndpointSecretStore = InMemoryEndpointSecretStore(),
    codexFound: Bool = true
  ) -> any AgentProvider {
    EndpointAgentProvider.make(
      endpoint: endpoint, claudeCode: Self.claude(), codex: Self.codex(found: codexFound),
      gateway: gateway, secrets: secrets)
  }

  @Test("Registered under its own identifier and name, offering only the models that call tools")
  func describesItself() async {
    let endpoint = Self.endpoint(authentication: .none)
    let provider = provider(endpoint)
    #expect(provider.descriptor.id.rawValue == endpoint.providerID)
    #expect(provider.descriptor.id.isEndpoint)
    #expect(provider.descriptor.displayName == "Ollama")
    #expect(await provider.models().map(\.id) == ["qwen3-coder:30b"])
  }

  @Test("Usable without signing in to the harness; not without its key, nor after a failed test")
  func availability() async {
    let noKey = Self.endpoint()
    #expect(await provider(noKey).availability(forceRefresh: false).isUsable == false)

    let secrets = InMemoryEndpointSecretStore(secrets: [noKey.id: "sk-1"])
    let ready = await provider(noKey, secrets: secrets).availability(forceRefresh: false)
    // Claude Code answers "signed out" to its probe: irrelevant, the gateway holds the key.
    #expect(ready.isUsable)
    #expect(ready.diagnostic.summary.contains("Claude Code"))

    var failed = noKey
    failed.lastTest = EndpointTestOutcome(verdict: .failed, date: Date())
    #expect(
      await provider(failed, secrets: secrets).availability(forceRefresh: false).isUsable == false)

    let codexMissing = Self.endpoint(wire: .responses, authentication: .none)
    let missing = await provider(codexMissing, codexFound: false).availability(forceRefresh: false)
    #expect(missing.state == .notFound)
  }

  @Test("A plan is the harness's, under the endpoint's name, and starts nothing")
  func planStartsNothing() async throws {
    let gateway = RecordingGateway()
    let endpoint = Self.endpoint(authentication: .none)
    let plan = try await provider(endpoint, gateway: gateway).launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: "/tmp", modelID: "qwen3-coder:30b"))
    #expect(plan.providerID.rawValue == endpoint.providerID)
    #expect(plan.executablePath == "/opt/homebrew/bin/claude")
    #expect(plan.arguments.contains("qwen3-coder:30b"))
    #expect(await gateway.started == 0)
    await #expect(throws: AgentLaunchError.unsupportedModel("llama3.2:3b")) {
      try await provider(endpoint).launchPlan(
        for: AgentLaunchRequest(workingDirectoryPath: "/tmp", modelID: "llama3.2:3b"))
    }
  }

  @Test("Prepared for Claude Code: the gateway, a token of its own, the model everywhere, no key")
  func preparesClaudeCode() async throws {
    let gateway = RecordingGateway()
    let endpoint = Self.endpoint(authentication: .none)
    let session = SessionID()
    let provider = EndpointAgentProvider(
      endpoint: endpoint, harness: .claudeCode(Self.claude()), gateway: gateway,
      secrets: InMemoryEndpointSecretStore(), makeToken: { "tok123" })
    var plan = try await provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: "/tmp", modelID: "qwen3-coder:30b"))
    plan = plan.adding(options: [], environment: ["ANTHROPIC_API_KEY": "sk-user"])
    let prepared = try await provider.preparingLaunch(plan, session: session)

    #expect(prepared.environment["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:61234/s/tok123")
    #expect(prepared.environment["ANTHROPIC_AUTH_TOKEN"] == "tok123")
    #expect(prepared.environment["ANTHROPIC_MODEL"] == "qwen3-coder:30b")
    #expect(prepared.environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"] == "qwen3-coder:30b")
    #expect(prepared.environment["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] == "65536")
    #expect(prepared.environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] == "65536")
    #expect(prepared.environment["ANTHROPIC_API_KEY"] == nil)
    let registered = await gateway.registered
    #expect(registered.count == 1)
    #expect(registered.first?.token == "tok123")
    #expect(registered.first?.model == "qwen3-coder:30b")
    #expect(registered.first?.session == session)
  }

  @Test(
    "Prepared for Codex: its provider set on the command line, before `--`, token in its variable")
  func preparesCodex() async throws {
    let endpoint = Self.endpoint(wire: .responses, authentication: .none)
    let provider = EndpointAgentProvider(
      endpoint: endpoint, harness: .codex(Self.codex()), gateway: RecordingGateway(),
      secrets: InMemoryEndpointSecretStore(), makeToken: { "tok9" })
    let plan = try await provider.launchPlan(
      for: AgentLaunchRequest(
        workingDirectoryPath: "/tmp", modelID: "qwen3-coder:30b", initialPrompt: "Fix it"))
    let prepared = try await provider.preparingLaunch(plan, session: SessionID())
    let arguments = prepared.arguments
    #expect(prepared.environment["VIBE_ENDPOINT_TOKEN"] == "tok9")
    #expect(arguments.contains(#"model_provider="vibe-endpoint""#))
    #expect(
      arguments.contains(
        #"model_providers.vibe-endpoint={name="Ollama",base_url="http://127.0.0.1:61234/s/tok9/v1",env_key="VIBE_ENDPOINT_TOKEN",wire_api="responses"}"#
      ))
    #expect(arguments.contains("model_context_window=65536"))
    #expect(arguments.contains("model_auto_compact_token_limit=58982"))
    if let separator = arguments.firstIndex(of: "--"),
      let option = arguments.firstIndex(of: #"model_provider="vibe-endpoint""#)
    {
      #expect(option < separator)
    }
  }

  @Test("A gateway that cannot start stops the launch with its reason")
  func gatewayFailure() async throws {
    let gateway = RecordingGateway()
    await gateway.fail(with: .couldNotStart(reason: "no binary"))
    let provider = EndpointAgentProvider(
      endpoint: Self.endpoint(authentication: .none), harness: .claudeCode(Self.claude()),
      gateway: gateway, secrets: InMemoryEndpointSecretStore())
    let plan = try await provider.launchPlan(for: AgentLaunchRequest(workingDirectoryPath: "/tmp"))
    await #expect(throws: EndpointGatewayError.couldNotStart(reason: "no binary")) {
      try await provider.preparingLaunch(plan, session: SessionID())
    }
  }

  @Test("Automatic picks the harness that needs no translation, Claude Code otherwise")
  func automaticHarness() {
    #expect(EndpointHarnessChoice.automatic.resolved(for: .messages) == .claudeCode)
    #expect(EndpointHarnessChoice.automatic.resolved(for: .responses) == .codex)
    #expect(EndpointHarnessChoice.automatic.resolved(for: .chatCompletions) == .claudeCode)
    #expect(EndpointHarnessChoice.codex.resolved(for: .messages) == .codex)
    let codexOne = provider(Self.endpoint(wire: .responses))
    #expect(codexOne is any AgentHookTrusting)
    #expect(!(provider(Self.endpoint()) is any AgentHookTrusting))
  }

  @Test("A model whose name holds a slash starts, under a name the CLI accepts")
  func slashedModel() async throws {
    let gateway = RecordingGateway()
    let endpoint = Self.endpoint(
      authentication: .none, models: [EndpointModel(id: "qwen/qwen3-coder", contextWindow: 262_144)])
    let provider = EndpointAgentProvider(
      endpoint: endpoint, harness: .claudeCode(Self.claude()), gateway: gateway,
      secrets: InMemoryEndpointSecretStore(), makeToken: { "t" })
    let plan = try await provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: "/tmp", modelID: "qwen/qwen3-coder"))
    #expect(plan.arguments.contains("qwen_qwen3-coder"))
    let prepared = try await provider.preparingLaunch(plan, session: SessionID())
    #expect(prepared.environment["ANTHROPIC_MODEL"] == "qwen_qwen3-coder")
    // The endpoint is asked for the real one.
    #expect(await gateway.registered.first?.model == "qwen/qwen3-coder")
  }

  @Test("A conversation another harness wrote is not resumed")
  func harnessChanged() async throws {
    let provider = EndpointAgentProvider(
      endpoint: Self.endpoint(authentication: .none), harness: .claudeCode(Self.claude()),
      gateway: RecordingGateway(), secrets: InMemoryEndpointSecretStore())
    await #expect(throws: AgentLaunchError.resumeUnsupported) {
      try await provider.launchPlan(
        for: AgentLaunchRequest(
          workingDirectoryPath: "/tmp", modelID: "qwen3-coder:30b",
          resume: .identifier("019e-codex"), harnessID: "codex"))
    }
    let resumed = try await provider.launchPlan(
      for: AgentLaunchRequest(
        workingDirectoryPath: "/tmp", modelID: "qwen3-coder:30b",
        resume: .identifier("5b1f4a86-3c0e-4c43-9d8e-2f0b6f1d7a10"), harnessID: "claude-code"))
    #expect(resumed.arguments.contains("--resume"))
  }

  @Test("The gateway's address also goes in Claude Code's settings, merged with the hooks'")
  func settingsEnvironment() async throws {
    let provider = EndpointAgentProvider(
      endpoint: Self.endpoint(authentication: .none), harness: .claudeCode(Self.claude()),
      gateway: RecordingGateway(), secrets: InMemoryEndpointSecretStore(), makeToken: { "tok" })
    var plan = try await provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: "/tmp", initialPrompt: "Go"))
    plan = plan.adding(options: ["--settings", #"{"hooks":{"Stop":[]}}"#])
    let prepared = try await provider.preparingLaunch(plan, session: SessionID())
    let flags = prepared.arguments.enumerated().filter { $0.element == "--settings" }
    #expect(flags.count == 1)
    let index = try #require(flags.first?.offset)
    let settings = try #require(
      try JSONSerialization.jsonObject(with: Data(prepared.arguments[index + 1].utf8))
        as? [String: Any])
    #expect(settings["hooks"] != nil)
    let env = try #require(settings["env"] as? [String: String])
    #expect(env["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:61234/s/tok")
    #expect(env["CLAUDE_CODE_USE_BEDROCK"] == "0")
    #expect(index < (prepared.arguments.firstIndex(of: "--") ?? prepared.arguments.endIndex))

    let alone = try await provider.preparingLaunch(
      try await provider.launchPlan(for: AgentLaunchRequest(workingDirectoryPath: "/tmp")),
      session: SessionID())
    #expect(alone.arguments.contains("--settings"))
  }

  @Test("The session's settings go in a file of its own, private, and the token is not argued")
  func settingsFile() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeGatewaySettings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let provider = EndpointAgentProvider(
      endpoint: Self.endpoint(authentication: .none), harness: .claudeCode(Self.claude()),
      gateway: RecordingGateway(), secrets: InMemoryEndpointSecretStore(),
      gatewayDirectory: folder, makeToken: { "secret-token" })
    let session = SessionID()
    let prepared = try await provider.preparingLaunch(
      try await provider.launchPlan(for: AgentLaunchRequest(workingDirectoryPath: "/tmp")),
      session: session)
    #expect(!prepared.arguments.joined(separator: " ").contains("secret-token"))
    let index = try #require(prepared.arguments.firstIndex(of: "--settings"))
    let file = URL(fileURLWithPath: prepared.arguments[index + 1])
    #expect(file.lastPathComponent == "\(session.rawValue.uuidString).json")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try String(contentsOf: file, encoding: .utf8).contains("secret-token"))
  }

  @Test("TOML strings are escaped as Codex reads them")
  func toml() {
    #expect(EndpointAgentProvider.toml(#"My "LLM" \ gw"#) == #""My \"LLM\" \\ gw""#)
  }

  @Test("The registry takes the endpoints in and out, after the command line agents")
  func registry() async {
    let registry = AgentProviderRegistry(providers: [Self.claude()])
    let endpoint = Self.endpoint(authentication: .none)
    await registry.replaceEndpoints([provider(endpoint)])
    #expect(await registry.descriptors().map(\.displayName) == ["Claude Code", "Ollama"])
    #expect(await registry.provider(id: AgentProviderID(endpoint.providerID)) != nil)
    await registry.replaceEndpoints([])
    #expect(await registry.provider(id: AgentProviderID(endpoint.providerID)) == nil)
    #expect(await registry.descriptors().count == 1)
  }
}
