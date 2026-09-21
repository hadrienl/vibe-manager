import Foundation

public enum AgentResumeRequest: Hashable, Sendable {
  case none
  case identifier(String)
}

public struct AgentLaunchRequest: Hashable, Sendable {
  public var workingDirectoryPath: String
  public var modelID: String?
  public var initialPrompt: String?
  public var resume: AgentResumeRequest
  public var additionalEnvironment: [String: String]

  public init(
    workingDirectoryPath: String,
    modelID: String? = nil,
    initialPrompt: String? = nil,
    resume: AgentResumeRequest = .none,
    additionalEnvironment: [String: String] = [:]
  ) {
    self.workingDirectoryPath = workingDirectoryPath
    self.modelID = modelID
    self.initialPrompt = initialPrompt
    self.resume = resume
    self.additionalEnvironment = additionalEnvironment
  }
}

/// How the initial prompt reaches the agent once the terminal runtime owns the process.
public enum PromptDelivery: Hashable, Sendable {
  case none
  case argument
  case standardInput(String)
}

public struct AgentLaunchPlan: Hashable, Sendable {
  public let providerID: AgentProviderID
  public let executablePath: String
  public let arguments: [String]
  public let environment: [String: String]
  public let workingDirectoryPath: String
  public let promptDelivery: PromptDelivery
  public let version: AgentVersion?

  public init(
    providerID: AgentProviderID,
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    workingDirectoryPath: String,
    promptDelivery: PromptDelivery,
    version: AgentVersion? = nil
  ) {
    self.providerID = providerID
    self.executablePath = executablePath
    self.arguments = arguments
    self.environment = environment
    self.workingDirectoryPath = workingDirectoryPath
    self.promptDelivery = promptDelivery
    self.version = version
  }

  public var executableURL: URL {
    URL(fileURLWithPath: executablePath)
  }

  public var workingDirectoryURL: URL {
    URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
  }
}

public enum AgentLaunchError: Error, Equatable, Sendable, LocalizedError {
  case unavailable(AgentAvailabilityState)
  case unsupportedModel(String)
  case modelSelectionUnsupported
  case initialPromptUnsupported
  case resumeUnsupported
  case missingResumeIdentifier
  case invalidWorkingDirectory
  case promptTooLarge(byteCount: Int, limit: Int)

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      return "The coding agent is not available on this Mac."
    case .unsupportedModel(let id):
      return "The model \(id) is not offered by this agent."
    case .modelSelectionUnsupported:
      return "This agent does not let Vibe Manager choose a model."
    case .initialPromptUnsupported:
      return "This agent does not accept an initial prompt."
    case .resumeUnsupported:
      return "This agent cannot resume a previous session."
    case .missingResumeIdentifier:
      return "The session has no resume identifier to hand to the agent."
    case .invalidWorkingDirectory:
      return "The working directory is not a usable absolute path."
    case .promptTooLarge(_, let limit):
      return "The initial prompt exceeds the \(limit) byte limit accepted by the agent."
    }
  }
}

/// Size thresholds shared by every command line provider.
public enum AgentPromptLimits {
  /// Beyond this size the prompt moves from `argv` to the standard input, well below the
  /// system `ARG_MAX` so environment and arguments always fit together.
  public static let argumentByteLimit = 16 * 1024
  /// Hard ceiling, whatever the delivery mode.
  public static let maximumByteLimit = 1024 * 1024
}
