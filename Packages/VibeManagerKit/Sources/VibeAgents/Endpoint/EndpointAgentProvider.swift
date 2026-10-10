import Foundation
import VibeApplication
import VibeDomain

/// An endpoint the user declared, as an agent among the others (#107).
///
/// Its sessions run Claude Code or Codex — the harness — pointed at the gateway, which translates
/// between the harness's protocol and the endpoint's. So a session on an endpoint is a real session
/// of that CLI: its terminal, its transcript, its hooks, its prompts and its resume are the CLI's,
/// and every feature built on them works unchanged. This type only says so: it relays each of those
/// capabilities to the harness, and adds what points the harness at the gateway.
///
/// What it does not relay, on purpose: journal summaries, themes and avatars. They run the CLI
/// once, on the user's own account with its maker, and would send an endpoint session's content to
/// a provider the user chose not to use for it.
public struct EndpointAgentProvider: AgentProvider {
  public enum Harness: Sendable {
    case claudeCode(ClaudeCodeAgentProvider)
    case codex(CodexAgentProvider)
  }

  public let endpoint: Endpoint
  let harness: Harness
  private let journals = JournalIndex()
  private let gateway: any EndpointGatewayControlling
  private let secrets: any EndpointSecretStore
  private let makeToken: @Sendable () -> String
  /// Where the gateway keeps what it saw of each session: see `EndpointConversationDecoder`.
  private let gatewayDirectory: URL?

  public init(
    endpoint: Endpoint,
    harness: Harness,
    gateway: any EndpointGatewayControlling,
    secrets: any EndpointSecretStore,
    gatewayDirectory: URL? = nil,
    makeToken: @escaping @Sendable () -> String = EndpointAgentProvider.randomToken
  ) {
    self.endpoint = endpoint
    self.harness = harness
    self.gateway = gateway
    self.secrets = secrets
    self.gatewayDirectory = gatewayDirectory
    self.makeToken = makeToken
  }

  /// The provider for `endpoint`, with the harness its settings resolve to. A Codex harness gets
  /// the type that also relays Codex's approval of hooks.
  public static func make(
    endpoint: Endpoint,
    claudeCode: ClaudeCodeAgentProvider,
    codex: CodexAgentProvider,
    gateway: any EndpointGatewayControlling,
    secrets: any EndpointSecretStore,
    gatewayDirectory: URL? = nil
  ) -> any AgentProvider {
    switch endpoint.harness.resolved(for: endpoint.wireProtocol) {
    case .claudeCode:
      return EndpointAgentProvider(
        endpoint: endpoint, harness: .claudeCode(claudeCode), gateway: gateway, secrets: secrets,
        gatewayDirectory: gatewayDirectory)
    case .codex:
      return CodexEndpointAgentProvider(
        base: EndpointAgentProvider(
          endpoint: endpoint, harness: .codex(codex), gateway: gateway, secrets: secrets,
          gatewayDirectory: gatewayDirectory),
        codex: codex)
    }
  }

  /// 256 random bits: what a session's harness shows the gateway, and nothing else can guess.
  public static let randomToken: @Sendable () -> String = {
    var generator = SystemRandomNumberGenerator()
    return (0..<4).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
  }

  var harnessProvider: any AgentProvider {
    switch harness {
    case .claudeCode(let provider): return provider
    case .codex(let provider): return provider
    }
  }

  var harnessKind: EndpointHarness {
    switch harness {
    case .claudeCode: return .claudeCode
    case .codex: return .codex
    }
  }

  public var descriptor: AgentDescriptor {
    AgentDescriptor(
      id: AgentProviderID(endpoint.providerID),
      displayName: endpoint.name,
      symbolName: "point.3.connected.trianglepath.dotted",
      minimumVersion: nil,
      capabilities: AgentCapabilities(
        supportsModelSelection: true,
        supportsInitialPrompt: true,
        supportsResume: true,
        reportsUsage: true))
  }

  /// Usable when its harness is installed, its settings are complete, its secret is in the
  /// keychain and its last test did not fail. Nothing is sent to the endpoint to find out: opening
  /// a sheet must not cost a request, nor wake a local model.
  public func availability(forceRefresh: Bool) async -> AgentAvailability {
    let base = await harnessProvider.availability(forceRefresh: forceRefresh)
    let harnessName = harnessProvider.descriptor.displayName
    let now = Date()
    func unusable(_ summary: String) -> AgentAvailability {
      let state = AgentAvailabilityState.probeFailed(reason: .failed(exitCode: 1))
      return AgentAvailability(
        state: state, installation: base.installation,
        diagnostic: AgentDiagnostic(
          providerID: descriptor.id, providerName: endpoint.name, state: state, summary: summary,
          installation: base.installation, probedAt: now, remediations: []))
    }
    switch base.state {
    case .available, .unauthenticated:
      // Signing in to the harness is not needed: the endpoint's key is given to the gateway.
      break
    default:
      return AgentAvailability(
        state: base.state, installation: base.installation,
        diagnostic: AgentDiagnostic(
          providerID: descriptor.id, providerName: endpoint.name, state: base.state,
          summary: String(
            localized: "\(harnessName) drives this endpoint: \(base.diagnostic.summary)",
            bundle: .module),
          detail: base.diagnostic.detail, installation: base.installation, probedAt: now,
          remediations: base.diagnostic.remediations))
    }
    if endpoint.validationIssues.contains(.noToolModel) {
      return unusable(
        String(
          localized: "No model of this endpoint can call tools. Add one in Settings → Endpoints.",
          bundle: .module))
    }
    if !endpoint.validationIssues.isEmpty {
      return unusable(
        String(
          localized: "The endpoint's settings are incomplete. Finish them in Settings → Endpoints.",
          bundle: .module))
    }
    if endpoint.authentication.needsSecret, !secrets.hasSecret(for: endpoint.id) {
      return unusable(
        String(
          localized: "Its key is not in the keychain. Add it in Settings → Endpoints.",
          bundle: .module))
    }
    if endpoint.lastTest?.verdict == .failed {
      return unusable(
        String(
          localized: "Its last test failed. Test it again in Settings → Endpoints.",
          bundle: .module))
    }
    let count = endpoint.agentModels.count
    let state = AgentAvailabilityState.available
    return AgentAvailability(
      state: state, installation: base.installation,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id, providerName: endpoint.name, state: state,
        summary: String(localized: "Endpoint via \(harnessName)", bundle: .module) + " · "
          + String(
            localized: "\(count) models", bundle: .module,
            comment: "How many models an endpoint offers."),
        installation: base.installation, probedAt: now, remediations: []))
  }

  public func models() async -> [AgentModel] {
    endpoint.agentModels.enumerated().map { index, model in
      AgentModel(id: model.id, displayName: model.displayName ?? model.id, isDefault: index == 0)
    }
  }

  /// The harness's own plan, for the endpoint's model, under the endpoint's identifier. Nothing is
  /// started here: see `preparingLaunch`.
  public func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    guard let model = request.modelID ?? endpoint.agentModels.first?.id else {
      throw AgentLaunchError.unavailable(.probeFailed(reason: .failed(exitCode: 1)))
    }
    guard endpoint.agentModels.contains(where: { $0.id == model }) else {
      throw AgentLaunchError.unsupportedModel(model)
    }
    // A conversation is resumed by the CLI that wrote it: an endpoint whose harness changed since
    // starts a new one, handed a summary like a switch of agent.
    if case .identifier = request.resume, let recorded = request.harnessID,
      recorded != harnessKind.providerID
    {
      throw AgentLaunchError.resumeUnsupported
    }
    var harnessRequest = request
    harnessRequest.modelID = Self.harnessModelName(model)
    let plan = try await harnessProvider.launchPlan(for: harnessRequest)
    return AgentLaunchPlan(
      providerID: descriptor.id, executablePath: plan.executablePath, arguments: plan.arguments,
      environment: plan.environment, workingDirectoryPath: plan.workingDirectoryPath,
      promptDelivery: plan.promptDelivery, version: plan.version)
  }

  /// The name the harness is given for a model. The CLIs refuse a `/` in a model's name, and
  /// OpenRouter's all have one (`qwen/qwen3-coder`): the harness is told a name without it, and
  /// the gateway asks the endpoint for the real one, which only the session's route holds.
  static func harnessModelName(_ id: String) -> String {
    id.replacingOccurrences(of: "/", with: "_")
  }

  /// The endpoint's model a plan runs, from the name its harness was told on its command line.
  func model(in plan: AgentLaunchPlan) -> String? {
    for flag in ["--model", "-m"] {
      if let index = plan.arguments.firstIndex(of: flag), index + 1 < plan.arguments.count {
        let name = plan.arguments[index + 1]
        return endpoint.models.first { Self.harnessModelName($0.id) == name }?.id ?? name
      }
    }
    return nil
  }
}

extension EndpointAgentProvider: AgentLaunchPreparing {
  /// Starts the gateway if needed, gives the session a token of its own, and points the harness at
  /// the gateway with it. The endpoint's key never reaches the harness: the gateway reads it from
  /// the keychain.
  public func preparingLaunch(_ plan: AgentLaunchPlan, session: SessionID) async throws
    -> AgentLaunchPlan
  {
    guard let model = model(in: plan) ?? endpoint.agentModels.first?.id else { return plan }
    let harnessName = Self.harnessModelName(model)
    // The token first: a gateway about to stop for want of any would otherwise stop between the
    // two, and leave the session an address nobody answers.
    let token = makeToken()
    try await gateway.register(token: token, endpoint: endpoint.id, model: model, session: session)
    let base = try await gateway.ensureRunning()
    let root = base.appendingPathComponent("s").appendingPathComponent(token)
    switch harness {
    case .claudeCode:
      var environment: [String: String] = [
        "ANTHROPIC_BASE_URL": root.absoluteString,
        "ANTHROPIC_AUTH_TOKEN": token,
        "ANTHROPIC_MODEL": harnessName,
        // Claude Code runs its side tasks — titles, summaries — on a smaller model: the same one,
        // so that nothing of the session goes elsewhere.
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": harnessName,
        "ANTHROPIC_DEFAULT_SONNET_MODEL": harnessName,
        "ANTHROPIC_DEFAULT_OPUS_MODEL": harnessName,
        "ANTHROPIC_SMALL_FAST_MODEL": harnessName,
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
      ]
      if let window = endpoint.models.first(where: { $0.id == model })?.contextWindow {
        // Read by Claude Code 2.1 for a model it does not know: its window, and when to compact.
        // Without them it assumes the window of its own models, and a smaller one refuses the
        // conversation before it is ever compacted.
        environment["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = String(window)
        environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = String(window)
      }
      // Another provider the user set for Claude Code would take the session elsewhere.
      environment["CLAUDE_CODE_USE_BEDROCK"] = "0"
      environment["CLAUDE_CODE_USE_VERTEX"] = "0"
      var prepared = plan.adding(options: [], environment: environment)
      // A key of the user's own would win over the token.
      prepared = prepared.removingEnvironment(["ANTHROPIC_API_KEY"])
      // Claude Code applies the `env` of its settings over its process's environment, the
      // settings given on its command line last: an `ANTHROPIC_BASE_URL` in the user's own would
      // send the session past the gateway. The same variables go there too.
      // In a file of the session's, private to the user: on the command line, the token would be
      // readable by every account of this Mac.
      let file = gatewayDirectory.map {
        $0.appendingPathComponent("settings", isDirectory: true)
          .appendingPathComponent("\(session.rawValue.uuidString).json")
      }
      return try Self.addingSettingsEnvironment(environment, to: prepared, file: file)
    case .codex:
      let provider = "vibe-endpoint"
      var options = [
        "-c", "model_provider=\"\(provider)\"",
        "-c",
        "model_providers.\(provider)={name=\(Self.toml(endpoint.name)),"
          + "base_url=\(Self.toml(root.appendingPathComponent("v1").absoluteString)),"
          + "env_key=\"\(Self.tokenVariable)\",wire_api=\"responses\"}",
      ]
      if let window = endpoint.models.first(where: { $0.id == model })?.contextWindow {
        options += [
          "-c", "model_context_window=\(window)",
          // Compacted at nine tenths, before the endpoint refuses the conversation.
          "-c", "model_auto_compact_token_limit=\(window * 9 / 10)",
        ]
      }
      return plan.adding(options: options, environment: [Self.tokenVariable: token])
    }
  }

  static let tokenVariable = "VIBE_ENDPOINT_TOKEN"

  /// `environment` in the `env` of the plan's `--settings`, merged with what the hooks put there
  /// (#45). Written to `file`, readable by the user alone, and given to Claude Code by its path;
  /// without a file — in tests — given inline.
  static func addingSettingsEnvironment(
    _ environment: [String: String], to plan: AgentLaunchPlan, file: URL? = nil
  ) throws -> AgentLaunchPlan {
    var arguments = plan.arguments
    let separator = arguments.firstIndex(of: "--") ?? arguments.endIndex
    var settings: [String: Any] = [:]
    var flag = arguments[..<separator].firstIndex(of: "--settings")
    if let index = flag, index + 1 < separator,
      let existing = (try? JSONSerialization.jsonObject(with: Data(arguments[index + 1].utf8)))
        as? [String: Any]
    {
      settings = existing
    }
    var env = settings["env"] as? [String: Any] ?? [:]
    for (key, value) in environment { env[key] = value }
    settings["env"] = env
    let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
    var value = String(decoding: data, as: UTF8.self)
    if let file {
      let folder = file.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let temporary = folder.appendingPathComponent(".\(UUID().uuidString).json")
      guard
        FileManager.default.createFile(
          atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
      else { throw CocoaError(.fileWriteUnknown) }
      _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
      value = file.path
    }
    if let index = flag, index + 1 < separator {
      arguments[index + 1] = value
    } else {
      arguments.insert(contentsOf: ["--settings", value], at: separator)
      flag = separator
    }
    return AgentLaunchPlan(
      providerID: plan.providerID, executablePath: plan.executablePath, arguments: arguments,
      environment: plan.environment, workingDirectoryPath: plan.workingDirectoryPath,
      promptDelivery: plan.promptDelivery, version: plan.version)
  }

  /// A TOML basic string.
  static func toml(_ value: String) -> String {
    var escaped = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": escaped += "\\\""
      case "\\": escaped += "\\\\"
      case "\n": escaped += "\\n"
      case "\t": escaped += "\\t"
      case let control where control.value < 0x20:
        escaped += String(format: "\\u%04X", control.value)
      default: escaped.unicodeScalars.append(scalar)
      }
    }
    return escaped + "\""
  }
}

extension AgentLaunchPlan {
  func removingEnvironment(_ keys: [String]) -> AgentLaunchPlan {
    var environment = self.environment
    for key in keys { environment[key] = nil }
    return AgentLaunchPlan(
      providerID: providerID, executablePath: executablePath, arguments: arguments,
      environment: environment, workingDirectoryPath: workingDirectoryPath,
      promptDelivery: promptDelivery, version: version)
  }
}

// MARK: - What the harness does, relayed

extension EndpointAgentProvider: AgentLaunchObserverProviding {
  public func launchObserver(for sessionID: SessionID, repository: any SessionRepository)
    -> any AgentLaunchObserver
  {
    let recording = AgentResumeRecording(
      providerID: endpoint.providerID, harnessID: harnessKind.providerID)
    switch harness {
    case .claudeCode(let provider):
      return provider.launchObserver(for: sessionID, repository: repository, recording: recording)
    case .codex(let provider):
      return CodexLaunchObserver(
        sessionID: sessionID, repository: repository, provider: provider, recording: recording)
    }
  }
}

extension EndpointAgentProvider: AgentActivityReporting {
  public func reportingActivity(_ plan: AgentLaunchPlan, to log: URL) -> AgentLaunchPlan {
    switch harness {
    case .claudeCode(let provider): return provider.reportingActivity(plan, to: log)
    case .codex(let provider): return provider.reportingActivity(plan, to: log)
    }
  }

  public func activityDecoder() -> any AgentSignalDecoding {
    switch harness {
    case .claudeCode(let provider): return provider.activityDecoder()
    case .codex(let provider): return provider.activityDecoder()
    }
  }

  public func activityDecoder(workingDirectoryPath: String?, environment: [String: String])
    -> any AgentSignalDecoding
  {
    switch harness {
    case .claudeCode(let provider):
      return provider.activityDecoder(
        workingDirectoryPath: workingDirectoryPath, environment: environment)
    case .codex(let provider):
      return provider.activityDecoder(
        workingDirectoryPath: workingDirectoryPath, environment: environment)
    }
  }
}

extension EndpointAgentProvider: AgentToolServing {
  public func providingTools(_ servers: [AgentToolServer], to plan: AgentLaunchPlan)
    -> AgentLaunchPlan
  {
    switch harness {
    case .claudeCode(let provider): return provider.providingTools(servers, to: plan)
    case .codex(let provider): return provider.providingTools(servers, to: plan)
    }
  }
}

extension EndpointAgentProvider: AgentInstructing {
  public func instructing(_ instructions: String, to plan: AgentLaunchPlan) -> AgentLaunchPlan {
    switch harness {
    case .claudeCode(let provider): return provider.instructing(instructions, to: plan)
    case .codex(let provider): return provider.instructing(instructions, to: plan)
    }
  }
}

extension EndpointAgentProvider: AgentConversationReporting {
  private var conversation: any AgentConversationReporting {
    switch harness {
    case .claudeCode(let provider): return provider
    case .codex(let provider): return provider
    }
  }

  public func conversationFiles(
    for conversation: SessionAgentConfiguration, in session: WorkSession,
    hint: AgentActivityEvent?
  ) -> [URL] {
    let files = self.conversation.conversationFiles(for: conversation, in: session, hint: hint)
    // The journal travels with the file the decoder is made for: the session is not given to it.
    if let gatewayDirectory {
      journals.set(
        GatewayStepRecord.file(for: session.id, in: gatewayDirectory), for: files)
    }
    return files
  }

  public func conversationDecoder(for file: URL) -> any ConversationDecoding {
    let decoder = conversation.conversationDecoder(for: file)
    guard let journal = journals.journal(for: file) else { return decoder }
    return EndpointConversationDecoder(inner: decoder, journal: journal)
  }

  public var promptFormat: AgentPromptFormat { conversation.promptFormat }

  public func subagentTranscripts(beside root: URL, agentIDs: Set<String>)
    -> [SubagentTranscriptInfo]
  {
    conversation.subagentTranscripts(beside: root, agentIDs: agentIDs)
  }

  public func subagentDecoder(for file: URL, root: URL) -> any ConversationDecoding {
    conversation.subagentDecoder(for: file, root: root)
  }

  public func firstPrompt(ofSubagent file: URL) -> String? {
    conversation.firstPrompt(ofSubagent: file)
  }
}

/// An endpoint Codex drives: everything above, and Codex's approval of the hooks it runs.
public struct CodexEndpointAgentProvider: AgentProvider, AgentHookTrusting {
  let base: EndpointAgentProvider
  private let codex: CodexAgentProvider

  init(base: EndpointAgentProvider, codex: CodexAgentProvider) {
    self.base = base
    self.codex = codex
  }

  public var endpoint: Endpoint { base.endpoint }
  public var descriptor: AgentDescriptor { base.descriptor }
  public func availability(forceRefresh: Bool) async -> AgentAvailability {
    await base.availability(forceRefresh: forceRefresh)
  }
  public func models() async -> [AgentModel] { await base.models() }
  public func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    try await base.launchPlan(for: request)
  }

  public func hookTrust(for plan: AgentLaunchPlan) async -> AgentHookTrust {
    await codex.hookTrust(for: plan)
  }

  public func trustHooks(of plan: AgentLaunchPlan) async throws {
    try await codex.trustHooks(of: plan)
  }
}

extension CodexEndpointAgentProvider: AgentLaunchPreparing, AgentLaunchObserverProviding,
  AgentActivityReporting, AgentToolServing, AgentInstructing, AgentConversationReporting
{
  public func instructing(_ instructions: String, to plan: AgentLaunchPlan) -> AgentLaunchPlan {
    base.instructing(instructions, to: plan)
  }

  public func preparingLaunch(_ plan: AgentLaunchPlan, session: SessionID) async throws
    -> AgentLaunchPlan
  {
    try await base.preparingLaunch(plan, session: session)
  }

  public func launchObserver(for sessionID: SessionID, repository: any SessionRepository)
    -> any AgentLaunchObserver
  {
    base.launchObserver(for: sessionID, repository: repository)
  }

  public func reportingActivity(_ plan: AgentLaunchPlan, to log: URL) -> AgentLaunchPlan {
    base.reportingActivity(plan, to: log)
  }

  public func activityDecoder() -> any AgentSignalDecoding { base.activityDecoder() }

  public func activityDecoder(workingDirectoryPath: String?, environment: [String: String])
    -> any AgentSignalDecoding
  {
    base.activityDecoder(workingDirectoryPath: workingDirectoryPath, environment: environment)
  }

  public func providingTools(_ servers: [AgentToolServer], to plan: AgentLaunchPlan)
    -> AgentLaunchPlan
  {
    base.providingTools(servers, to: plan)
  }

  public func conversationFiles(
    for conversation: SessionAgentConfiguration, in session: WorkSession,
    hint: AgentActivityEvent?
  ) -> [URL] {
    base.conversationFiles(for: conversation, in: session, hint: hint)
  }

  public func conversationDecoder(for file: URL) -> any ConversationDecoding {
    base.conversationDecoder(for: file)
  }

  public var promptFormat: AgentPromptFormat { base.promptFormat }

  public func subagentTranscripts(beside root: URL, agentIDs: Set<String>)
    -> [SubagentTranscriptInfo]
  {
    base.subagentTranscripts(beside: root, agentIDs: agentIDs)
  }

  public func subagentDecoder(for file: URL, root: URL) -> any ConversationDecoding {
    base.subagentDecoder(for: file, root: root)
  }

  public func firstPrompt(ofSubagent file: URL) -> String? {
    base.firstPrompt(ofSubagent: file)
  }
}

/// Which gateway journal goes with which transcript file.
final class JournalIndex: @unchecked Sendable {
  private let lock = NSLock()
  private var journals: [URL: URL] = [:]

  func set(_ journal: URL, for files: [URL]) {
    lock.lock()
    for file in files { journals[file] = journal }
    lock.unlock()
  }

  func journal(for file: URL) -> URL? {
    lock.lock()
    defer { lock.unlock() }
    return journals[file]
  }
}
