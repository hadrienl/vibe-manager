import Foundation
import VibeApplication

/// Everything a concrete CLI has to declare so it can be detected and launched.
///
/// Adding Claude Code (#6) or Codex (#5) means writing a specification and an argument
/// builder, never touching detection, caching, diagnostics or the views.
public struct CommandLineAgentSpecification: Sendable {
  public let binaryName: String
  public let candidateDirectories: [String]
  public let versionArguments: [String]
  public let versionTimeout: Duration
  /// Optional command whose exit code hints at the sign in state. Never reads a token.
  public let authenticationArguments: [String]?
  /// Extra environment keys this CLI needs on top of the shared allow list.
  public let additionalEnvironmentKeys: Set<String>
  /// Where a user can read how to install or update this CLI.
  public let documentationURL: URL?
  /// The command a user types to sign in, shown by the authentication remediation.
  public let authenticationCommandLine: String?

  public init(
    binaryName: String,
    candidateDirectories: [String] = CommandLineAgentSpecification.defaultCandidateDirectories,
    versionArguments: [String] = ["--version"],
    versionTimeout: Duration = .seconds(5),
    authenticationArguments: [String]? = nil,
    additionalEnvironmentKeys: Set<String> = [],
    documentationURL: URL? = nil,
    authenticationCommandLine: String? = nil
  ) {
    self.binaryName = binaryName
    self.candidateDirectories = candidateDirectories
    self.versionArguments = versionArguments
    self.versionTimeout = versionTimeout
    self.authenticationArguments = authenticationArguments
    self.additionalEnvironmentKeys = additionalEnvironmentKeys
    self.documentationURL = documentationURL
    self.authenticationCommandLine = authenticationCommandLine
  }

  /// Where developer tools usually land on macOS, including version manager shims.
  public static let defaultCandidateDirectories = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "~/.local/bin",
    "~/bin",
    "~/.bun/bin",
    "~/.deno/bin",
    "~/.cargo/bin",
    "~/.npm-global/bin",
    "~/.volta/bin",
    "~/.asdf/shims",
    "~/.local/share/mise/shims",
    "/usr/bin",
  ]
}

/// Turns a launch request into the arguments of one specific CLI.
public protocol CommandLineAgentArgumentBuilder: Sendable {
  func arguments(
    for request: AgentLaunchRequest,
    promptDelivery: PromptDelivery,
    descriptor: AgentDescriptor
  ) throws -> [String]
}

/// A provider that detects a CLI, offers its models and builds launch plans for it.
public struct CommandLineAgentProvider: AgentProvider {
  public let descriptor: AgentDescriptor

  private let specification: CommandLineAgentSpecification
  private let availabilityProbe: AgentAvailabilityProbe
  private let argumentBuilder: any CommandLineAgentArgumentBuilder
  private let catalog: [AgentModel]
  private let environment: [String: String]

  public init(
    descriptor: AgentDescriptor,
    specification: CommandLineAgentSpecification,
    models: [AgentModel] = [],
    argumentBuilder: any CommandLineAgentArgumentBuilder,
    availabilityProbe: AgentAvailabilityProbe,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.descriptor = descriptor
    self.specification = specification
    catalog = models
    self.argumentBuilder = argumentBuilder
    self.availabilityProbe = availabilityProbe
    self.environment = environment
  }

  public func availability(forceRefresh: Bool) async -> AgentAvailability {
    await availabilityProbe.availability(forceRefresh: forceRefresh)
  }

  public func models() async -> [AgentModel] {
    catalog
  }

  public func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    let availability = await availability(forceRefresh: false)
    guard availability.isUsable, let installation = availability.installation else {
      throw AgentLaunchError.unavailable(availability.state)
    }
    return try plan(for: request, installation: installation)
  }

  /// Pure part of the launch: same installation and request always yield the same plan.
  public func plan(
    for request: AgentLaunchRequest,
    installation: AgentInstallation
  ) throws -> AgentLaunchPlan {
    try AgentLaunchValidation.validateWorkingDirectory(request.workingDirectoryPath)
    try AgentLaunchValidation.validateModel(request.modelID, in: catalog, descriptor: descriptor)
    try AgentLaunchValidation.validateResume(request.resume, descriptor: descriptor)
    let delivery = try AgentLaunchValidation.promptDelivery(
      for: request.initialPrompt,
      descriptor: descriptor
    )

    let arguments = try argumentBuilder.arguments(
      for: request,
      promptDelivery: delivery,
      descriptor: descriptor
    )

    return AgentLaunchPlan(
      providerID: descriptor.id,
      executablePath: installation.executablePath,
      arguments: arguments,
      environment: AgentEnvironmentPolicy.environment(
        base: environment,
        additionalKeys: specification.additionalEnvironmentKeys,
        overrides: request.additionalEnvironment
      ),
      workingDirectoryPath: request.workingDirectoryPath,
      promptDelivery: delivery,
      version: installation.version
    )
  }
}

/// Checks every provider must apply before building arguments.
public enum AgentLaunchValidation {
  public static func validateWorkingDirectory(_ path: String) throws {
    guard path.hasPrefix("/"), path.count > 1 else {
      throw AgentLaunchError.invalidWorkingDirectory
    }
  }

  public static func validateModel(
    _ modelID: String?,
    in catalog: [AgentModel],
    descriptor: AgentDescriptor
  ) throws {
    guard let modelID else { return }
    guard descriptor.capabilities.supportsModelSelection else {
      throw AgentLaunchError.modelSelectionUnsupported
    }
    guard catalog.isEmpty || catalog.contains(where: { $0.id == modelID }) else {
      throw AgentLaunchError.unsupportedModel(modelID)
    }
  }

  public static func validateResume(
    _ resume: AgentResumeRequest,
    descriptor: AgentDescriptor
  ) throws {
    switch resume {
    case .none:
      return
    case .identifier(let identifier):
      guard descriptor.capabilities.supportsResume else {
        throw AgentLaunchError.resumeUnsupported
      }
      guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AgentLaunchError.missingResumeIdentifier
      }
    }
  }

  /// A long prompt moves to the standard input instead of being pushed into `argv`.
  public static func promptDelivery(
    for prompt: String?,
    descriptor: AgentDescriptor
  ) throws -> PromptDelivery {
    guard let prompt, !prompt.isEmpty else { return .none }
    guard descriptor.capabilities.supportsInitialPrompt else {
      throw AgentLaunchError.initialPromptUnsupported
    }

    let byteCount = prompt.utf8.count
    guard byteCount <= AgentPromptLimits.maximumByteLimit else {
      throw AgentLaunchError.promptTooLarge(
        byteCount: byteCount,
        limit: AgentPromptLimits.maximumByteLimit
      )
    }
    return byteCount <= AgentPromptLimits.argumentByteLimit ? .argument : .standardInput(prompt)
  }
}
