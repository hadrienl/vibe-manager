import Foundation
import VibeApplication
import VibeDomain

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

  /// A second mock, with models of its own, so that switching agents can be driven end to end.
  public static let secondaryDescriptor = AgentDescriptor(
    id: AgentProviderID("mock-b"),
    displayName: "Mock Agent B",
    symbolName: "ant",
    minimumVersion: AgentVersion(major: 1, minor: 0, patch: 0),
    capabilities: AgentCapabilities(
      supportsModelSelection: true,
      supportsInitialPrompt: true,
      supportsResume: true,
      reportsUsage: false
    )
  )

  public static let secondaryModels = [
    AgentModel(id: "mock-b-small", displayName: "Mock B Small", isDefault: true),
    AgentModel(id: "mock-b-large", displayName: "Mock B Large"),
  ]

  public let descriptor: AgentDescriptor

  private let simulatedState: AgentAvailabilityState
  private let scriptURL: URL?
  private let environment: [String: String]
  private let now: @Sendable () -> Date
  private let catalog: [AgentModel]
  /// Passed to the script before anything else: `--hold`, `--flood 2048`, `--ignore-sigterm`…
  private let behaviour: [String]

  public init(
    simulatedState: AgentAvailabilityState = .available,
    scriptURL: URL? = MockAgentProvider.defaultScriptURL(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    now: @escaping @Sendable () -> Date = Date.init,
    secondary: Bool = false,
    behaviour: [String] = []
  ) {
    self.simulatedState = simulatedState
    self.scriptURL = scriptURL
    self.environment = environment
    self.now = now
    descriptor = secondary ? Self.secondaryDescriptor : Self.agentDescriptor
    catalog = secondary ? Self.secondaryModels : Self.availableModels
    self.behaviour = behaviour
  }

  public static func defaultScriptURL() -> URL? {
    Bundle.module.url(forResource: "mock-agent", withExtension: "sh")
  }

  /// Registered only when it is asked for, in any configuration.
  ///
  /// It used to appear by default in a Debug build, which put a fake agent in the list next to
  /// the real ones every time the application was run from Xcode. The exercise it exists for —
  /// driving the whole chain without Claude, Codex or an account — is deliberate enough to
  /// deserve an explicit `VIBE_ENABLE_MOCK_AGENT`.
  public static func isEnabled(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    environment["VIBE_ENABLE_MOCK_AGENT"] != nil
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
    catalog
  }

  public func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    let availability = await availability(forceRefresh: false)
    guard availability.isUsable, let installation = availability.installation else {
      throw AgentLaunchError.unavailable(availability.state)
    }

    try AgentLaunchValidation.validateWorkingDirectory(request.workingDirectoryPath)
    try AgentLaunchValidation.validateModel(
      request.modelID,
      in: catalog,
      descriptor: descriptor
    )
    try AgentLaunchValidation.validateResume(request.resume, descriptor: descriptor)
    let delivery = try AgentLaunchValidation.promptDelivery(
      for: request.initialPrompt,
      descriptor: descriptor
    )

    var arguments = [installation.executablePath] + behaviour
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

/// Keeps the identifier the mock prints, as the real providers keep theirs.
public actor MockLaunchObserver: AgentLaunchObserver {
  private let record: RecordAgentResumeIdentifier
  private let sessionID: SessionID
  private let extractor = MockResumeIdentifierExtractor()
  private var pending = ""
  private var isRecorded = false

  public init(sessionID: SessionID, record: RecordAgentResumeIdentifier) {
    self.sessionID = sessionID
    self.record = record
  }

  /// An identifier the plan names — `--session-id`, or `--resume` — is the one the mock will
  /// print: it is kept at once, as Claude Code's is, without waiting for output that may already
  /// have gone by.
  public func launched(plan: AgentLaunchPlan) async {
    for flag in ["--resume", "--session-id"] {
      guard let index = plan.arguments.firstIndex(of: flag), index + 1 < plan.arguments.count
      else { continue }
      await keep(plan.arguments[index + 1])
      return
    }
  }

  private func keep(_ identifier: String) async {
    isRecorded =
      (try? await record(sessionID: sessionID, identifier: identifier))?.isPersisted
      ?? false
  }

  public func observe(output: String) async {
    guard !isRecorded else { return }
    pending += output
    // Only whole lines: an identifier cut by a read would be recorded cut.
    guard let end = pending.lastIndex(of: "\n") else { return }
    let complete = String(pending[..<end])
    pending = String(pending[pending.index(after: end)...])
    guard let identifier = extractor.resumeIdentifier(in: complete) else { return }
    await keep(identifier)
  }

  public func finished() async {}
}

extension MockAgentProvider: AgentLaunchObserverProviding {
  public func launchObserver(
    for sessionID: SessionID,
    repository: any SessionRepository
  ) -> any AgentLaunchObserver {
    MockLaunchObserver(
      sessionID: sessionID,
      record: RecordAgentResumeIdentifier(
        repository: repository, providerID: descriptor.id.rawValue, launchedAt: now()))
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
