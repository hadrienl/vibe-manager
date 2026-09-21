import Foundation
import VibeApplication

/// A complete agent that needs neither Claude, Codex nor a network account.
///
/// It streams a few lines, honours the initial prompt, prints a resume identifier and can
/// simulate every availability state, so the whole chain can be exercised end to end.
public struct MockAgentProvider: AgentProvider {
  public static let id = AgentProviderID("mock")

  public static let agentDescriptor = AgentDescriptor(
    id: MockAgentProvider.id,
    displayName: "Mock Agent",
    symbolName: "ladybug",
    minimumVersion: AgentVersion(major: 1, minor: 0, patch: 0),
    capabilities: AgentCapabilities(
      supportsModelSelection: true,
      supportsInitialPrompt: true,
      supportsResume: true,
      reportsUsage: false
    )
  )

  public static let availableModels = [
    AgentModel(id: "mock-fast", displayName: "Mock Fast", isDefault: true),
    AgentModel(id: "mock-deep", displayName: "Mock Deep"),
  ]

  public let descriptor = MockAgentProvider.agentDescriptor

  private let simulatedState: AgentAvailabilityState
  private let scriptURL: URL?
  private let environment: [String: String]
  private let now: @Sendable () -> Date

  public init(
    simulatedState: AgentAvailabilityState = .available,
    scriptURL: URL? = MockAgentProvider.defaultScriptURL(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.simulatedState = simulatedState
    self.scriptURL = scriptURL
    self.environment = environment
    self.now = now
  }

  public static func defaultScriptURL() -> URL? {
    Bundle.module.url(forResource: "mock-agent", withExtension: "sh")
  }

  /// Registered only in Debug builds or when the dedicated variable is set, so a distributed
  /// Release build never lists it.
  public static func isEnabled(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    #if DEBUG
      return environment["VIBE_DISABLE_MOCK_AGENT"] == nil
    #else
      return environment["VIBE_ENABLE_MOCK_AGENT"] != nil
    #endif
  }

  public func availability(forceRefresh: Bool) async -> AgentAvailability {
    let date = now()
    guard case .available = simulatedState, let scriptURL else {
      return AgentDiagnosticFactory.availability(
        descriptor: descriptor,
        state: scriptURL == nil ? .notFound : simulatedState,
        installation: nil,
        detail: scriptURL == nil ? "The bundled mock agent script is missing." : "Simulated state.",
        at: date
      )
    }

    let installation = AgentInstallation(
      executablePath: scriptURL.path,
      version: AgentVersion(major: 1, minor: 0, patch: 0),
      rawVersionOutput: "mock-agent 1.0.0",
      source: .userDefined,
      detectedAt: date
    )
    return AgentDiagnosticFactory.availability(
      descriptor: descriptor,
      state: .available,
      installation: installation,
      detail: nil,
      at: date
    )
  }

  public func models() async -> [AgentModel] {
    MockAgentProvider.availableModels
  }

  public func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    let availability = await availability(forceRefresh: false)
    guard availability.isUsable, let installation = availability.installation else {
      throw AgentLaunchError.unavailable(availability.state)
    }

    try AgentLaunchValidation.validateWorkingDirectory(request.workingDirectoryPath)
    try AgentLaunchValidation.validateModel(
      request.modelID,
      in: MockAgentProvider.availableModels,
      descriptor: descriptor
    )
    try AgentLaunchValidation.validateResume(request.resume, descriptor: descriptor)
    let delivery = try AgentLaunchValidation.promptDelivery(
      for: request.initialPrompt,
      descriptor: descriptor
    )

    var arguments = [installation.executablePath]
    if let modelID = request.modelID {
      arguments.append(contentsOf: ["--model", modelID])
    }
    if case .identifier(let identifier) = request.resume {
      arguments.append(contentsOf: ["--resume", identifier])
    }
    if case .argument = delivery, let prompt = request.initialPrompt {
      arguments.append(contentsOf: ["--prompt", prompt])
    }
    if case .standardInput = delivery {
      arguments.append("--prompt-from-stdin")
    }

    return AgentLaunchPlan(
      providerID: descriptor.id,
      executablePath: "/bin/sh",
      arguments: arguments,
      environment: AgentEnvironmentPolicy.environment(
        base: environment,
        overrides: request.additionalEnvironment
      ),
      workingDirectoryPath: request.workingDirectoryPath,
      promptDelivery: delivery,
      version: installation.version
    )
  }
}

/// Reads the resume identifier the mock agent prints, the way #5 and #6 will for real CLIs.
public struct MockResumeIdentifierExtractor: AgentResumeIdentifierExtractor {
  private static let marker = "mock-session-id: "

  public init() {}

  public func resumeIdentifier(in chunk: String) -> String? {
    for line in chunk.split(separator: "\n") where line.hasPrefix(Self.marker) {
      let identifier = line.dropFirst(Self.marker.count).trimmingCharacters(in: .whitespaces)
      guard !identifier.isEmpty else { continue }
      return identifier
    }
    return nil
  }
}
