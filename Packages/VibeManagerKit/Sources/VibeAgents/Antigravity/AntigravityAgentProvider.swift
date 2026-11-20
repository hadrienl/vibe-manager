import Foundation
import VibeApplication
import VibeDomain

/// Google Antigravity's interactive CLI. Its settings and conversation format are its own,
/// independent of both Gemini CLI and Claude Code (#538).
public struct AntigravityAgentProvider: AgentProvider {
  public static let id = AgentProviderID("antigravity")
  public static let minimumVersion = AgentVersion(major: 1, minor: 5, patch: 5)
  public static let descriptor = AgentDescriptor(
    id: id, displayName: "Antigravity", symbolName: "sparkles", minimumVersion: minimumVersion,
    capabilities: AgentCapabilities(
      supportsModelSelection: true, supportsInitialPrompt: true, supportsResume: true,
      reportsUsage: false))
  public static let specification = CommandLineAgentSpecification(
    binaryName: "agy",
    additionalEnvironmentKeys: [
      "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
      "SSL_CERT_FILE", "SSL_CERT_DIR",
    ],
    documentationURL: URL(string: "https://antigravity.google/docs/getting-started?tab=cli"))

  private let base: CommandLineAgentProvider
  private let catalog: AntigravityModelCatalog
  private let approvalPreferences: (any AgentApprovalPreferences)?
  let home: URL

  public init(
    base: CommandLineAgentProvider, catalog: AntigravityModelCatalog,
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
    approvalPreferences: (any AgentApprovalPreferences)? = nil
  ) {
    self.base = base
    self.catalog = catalog
    self.home = home
    self.approvalPreferences = approvalPreferences
  }

  public static func make(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    diagnostics: any DiagnosticLog = NullDiagnosticLog(),
    shellEnvironment: (any ShellEnvironmentSource)? = nil,
    approvalPreferences: (any AgentApprovalPreferences)? = nil
  ) -> Self {
    let probe = SystemProcessProbe()
    let locator = FileSystemExecutableLocator(environment: environment, probe: probe)
    let availability = AgentAvailabilityProbe(
      descriptor: descriptor, specification: specification, locator: locator, probe: probe,
      environment: environment, diagnostics: diagnostics)
    let base = CommandLineAgentProvider(
      descriptor: descriptor, specification: specification, models: [],
      argumentBuilder: AntigravityArgumentBuilder(), availabilityProbe: availability,
      environment: environment, shellEnvironment: shellEnvironment)
    let home = URL(
      fileURLWithPath: environment["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        ?? NSHomeDirectory(), isDirectory: true)
    return Self(
      base: base,
      catalog: AntigravityModelCatalog(
        availability: availability, probe: probe,
        environment: AgentEnvironmentPolicy.environment(
          base: environment, additionalKeys: specification.additionalEnvironmentKeys)),
      home: home, approvalPreferences: approvalPreferences)
  }

  public var descriptor: AgentDescriptor { Self.descriptor }

  public func availability(forceRefresh: Bool) async -> AgentAvailability {
    await base.availability(forceRefresh: forceRefresh)
  }

  public func models() async -> [AgentModel] { await catalog.models() }

  public func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    var request = request
    if request.approvalMode == nil, let approvalPreferences {
      request.approvalMode = await approvalPreferences.mode(for: descriptor.id)
    }
    return try await base.launchPlan(for: request)
  }

  /// 1.5.5's status line reports an `antigravity/brain` path, but the CLI actually writes under
  /// `antigravity-cli/brain`. Use the path verified on disk, and never search other conversations.
  static func transcript(identifier: String, home: URL) -> URL? {
    guard let uuid = UUID(uuidString: identifier) else { return nil }
    return home.appendingPathComponent(
      ".gemini/antigravity-cli/brain/\(uuid.uuidString.lowercased())/.system_generated/logs/transcript.jsonl"
    )
  }
}

public struct AntigravityArgumentBuilder: CommandLineAgentArgumentBuilder {
  public init() {}

  public func arguments(
    for request: AgentLaunchRequest, promptDelivery: PromptDelivery, descriptor: AgentDescriptor
  ) throws -> [String] {
    // Both directions override persisted CLI defaults for this process only. `--mode` has no
    // value for the default mode, so Manual sets it in the session's settings instead:
    // `agentMode: ""` is the explicit Default (`/config` saves it so since Auto became the
    // default), not an absent value. Verified on 1.5.6: with a global `agentMode: "auto"`, a
    // write ran unasked without this override and was held for review with it. No mode chosen:
    // the user's own `/config` applies, untouched.
    var arguments: [String] =
      request.approvalMode == .autoReview ? ["--sandbox", "--mode", "auto"] : []
    if let mode = request.approvalMode {
      arguments += [
        "--settings",
        AntigravitySettings.json([
          "agentMode": mode == .autoReview ? "auto" : "",
          "toolPermission": mode == .autoReview ? "proceed-in-sandbox" : "request-review",
        ]),
      ]
    }
    if case .identifier(let identifier) = request.resume {
      guard let uuid = UUID(uuidString: identifier.trimmingCharacters(in: .whitespacesAndNewlines))
      else { throw AgentLaunchError.missingResumeIdentifier }
      arguments += ["--conversation", uuid.uuidString.lowercased()]
    }
    if let model = request.modelID {
      guard AgentArgumentToken.isWellFormedIdentifier(model) else {
        throw AgentLaunchError.unsupportedModel(model)
      }
      arguments += ["--model", model]
    }
    switch promptDelivery {
    case .none, .typedOnceReady: break
    case .argument:
      // An option value, not a positional. `--prompt` would switch to noninteractive mode.
      arguments += ["--prompt-interactive", request.initialPrompt ?? ""]
    case .standardInput(let prompt):
      throw AgentLaunchError.promptTooLarge(
        byteCount: prompt.utf8.count, limit: AgentPromptLimits.argumentByteLimit)
    }
    return arguments
  }
}

/// `agy` accepts one settings override. Keep permission policy and activity in the same JSON
/// object: repeating --settings lets the CLI keep only the last value. Parse known option values
/// as values, so a literal prompt equal to "--settings" cannot be mistaken for an option.
enum AntigravitySettings {
  static func json(_ object: [String: Any]) -> String {
    let data = try? JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }

  static func merging(_ settings: String, into plan: AgentLaunchPlan) -> AgentLaunchPlan {
    var arguments = plan.arguments
    var index = 0
    var settingsIndex: Int?
    while index < arguments.count {
      let option = arguments[index]
      if option == "--settings", index + 1 < arguments.count {
        settingsIndex = index + 1
        break
      }
      index +=
        ["--model", "--mode", "--conversation", "--prompt-interactive", "--effort"].contains(option)
        ? 2 : 1
    }
    var merged: [String: Any] = [:]
    if let settingsIndex {
      merged = object(arguments[settingsIndex])
    }
    merged.merge(object(settings)) { _, added in added }
    if let settingsIndex {
      arguments[settingsIndex] = json(merged)
    } else {
      arguments += ["--settings", json(merged)]
    }
    return AgentLaunchPlan(
      providerID: plan.providerID, executablePath: plan.executablePath, arguments: arguments,
      environment: plan.environment, workingDirectoryPath: plan.workingDirectoryPath,
      promptDelivery: plan.promptDelivery, version: plan.version)
  }

  private static func object(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
  }
}

/// One bounded, shared catalog request, cached briefly. A failed request never prevents using
/// the CLI's own default model, and no list is hard coded into the application.
public actor AntigravityModelCatalog {
  private let availability: AgentAvailabilityProbe
  private let probe: any ProcessProbe
  private let environment: [String: String]
  private var cached: [AgentModel] = []
  private var expires = ContinuousClock.now
  private var pending: Task<[AgentModel], Never>?

  public init(
    availability: AgentAvailabilityProbe, probe: any ProcessProbe, environment: [String: String]
  ) {
    self.availability = availability
    self.probe = probe
    self.environment = environment
  }

  public func models() async -> [AgentModel] {
    if let pending { return await pending.value }
    if ContinuousClock.now < expires { return cached }
    let task = Task { [availability, probe, environment] in
      let found = await availability.availability(forceRefresh: false)
      guard found.isUsable, let path = found.installation?.executablePath,
        let result = try? await probe.run(
          executablePath: path, arguments: ["models"], environment: environment,
          timeout: .seconds(15)),
        result.exitCode == 0, !result.didTimeOut, !result.outputTruncated
      else { return [AgentModel]() }
      return Self.decode(result.standardOutput)
    }
    pending = task
    cached = await task.value
    expires = ContinuousClock.now.advanced(by: cached.isEmpty ? .seconds(15) : .seconds(300))
    pending = nil
    return cached
  }

  static func decode(_ text: String) -> [AgentModel] {
    guard text.utf8.count <= 256 * 1024 else { return [] }
    var seen = Set<String>()
    return text.split(whereSeparator: \.isNewline).compactMap { line in
      let fields = line.split(separator: "\t", maxSplits: 1)
      guard fields.count == 2 else { return nil }
      let id = String(fields[0])
      let name = fields[1].trimmingCharacters(in: .whitespaces)
      guard AgentArgumentToken.isWellFormedIdentifier(id), !name.isEmpty,
        !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        seen.count < 200, seen.insert(id).inserted
      else { return nil }
      return AgentModel(id: id, displayName: String(name.prefix(256)))
    }
  }
}
