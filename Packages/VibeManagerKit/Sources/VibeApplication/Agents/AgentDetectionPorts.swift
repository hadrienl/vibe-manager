import Foundation

public struct ExecutableSearchPlan: Hashable, Sendable {
  public let binaryName: String
  /// Absolute or tilde prefixed directories probed before the inherited `PATH`.
  public let candidateDirectories: [String]
  /// Path explicitly configured by the user, which always wins.
  public let userDefinedPath: String?
  /// Whether a login shell may be asked for the binary location as a last resort.
  public let allowsLoginShellFallback: Bool

  public init(
    binaryName: String,
    candidateDirectories: [String] = [],
    userDefinedPath: String? = nil,
    allowsLoginShellFallback: Bool = true
  ) {
    self.binaryName = binaryName
    self.candidateDirectories = candidateDirectories
    self.userDefinedPath = userDefinedPath
    self.allowsLoginShellFallback = allowsLoginShellFallback
  }
}

public enum ExecutableLocation: Hashable, Sendable {
  case found(path: String, source: AgentDetectionSource)
  case notExecutable(path: String, source: AgentDetectionSource)
  /// The search could not be completed: the login shell never answered where the binary is.
  ///
  /// Distinct from `notFound`, which is an answer. A shell still sourcing its configuration has
  /// said nothing about the installation, and reporting it as missing sends the user off to
  /// install a CLI they already have.
  case timedOut
  case notFound
}

public protocol ExecutableLocator: Sendable {
  func locate(_ plan: ExecutableSearchPlan) async -> ExecutableLocation
}

public struct ProbeResult: Hashable, Sendable {
  public let exitCode: Int32
  public let standardOutput: String
  public let standardError: String
  public let didTimeOut: Bool

  public init(
    exitCode: Int32,
    standardOutput: String = "",
    standardError: String = "",
    didTimeOut: Bool = false
  ) {
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.didTimeOut = didTimeOut
  }

  public var combinedOutput: String {
    [standardOutput, standardError]
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }
}

public enum ProbeError: Error, Equatable, Sendable {
  case launchFailed
  case cancelled
}

extension Duration {
  /// Full precision conversion: truncating to whole seconds would silently disable any
  /// sub-second timeout or cache lifetime.
  public var seconds: Double {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}

/// Runs a short lived, non interactive command. Never used for the agent itself.
public protocol ProcessProbe: Sendable {
  func run(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    workingDirectoryPath: String?,
    timeout: Duration
  ) async throws -> ProbeResult
}

extension ProcessProbe {
  public func run(
    executablePath: String,
    arguments: [String],
    environment: [String: String] = [:],
    timeout: Duration = .seconds(5)
  ) async throws -> ProbeResult {
    try await run(
      executablePath: executablePath,
      arguments: arguments,
      environment: environment,
      workingDirectoryPath: nil,
      timeout: timeout
    )
  }
}

/// Builds the environment handed to an agent from an allow list.
///
/// Inheriting the full environment of the application would forward anything a launcher
/// injected, including secrets unrelated to the agent.
public enum AgentEnvironmentPolicy {
  public static let defaultAllowedKeys: Set<String> = [
    // `NVM_DIR` because nvm is often loaded lazily, by shell functions that source it from there:
    // without it, `npm` and `node` are missing from the shells the agent opens.
    "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "NVM_DIR", "PATH", "SHELL", "SSH_AUTH_SOCK",
    "TERM", "TERM_PROGRAM", "TMPDIR", "USER", "XDG_CACHE_HOME", "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
  ]

  public static func environment(
    base: [String: String],
    allowedKeys: Set<String> = defaultAllowedKeys,
    additionalKeys: Set<String> = [],
    overrides: [String: String] = [:]
  ) -> [String: String] {
    let allowed = allowedKeys.union(additionalKeys)
    var environment = base.filter { allowed.contains($0.key) }
    for (key, value) in overrides {
      environment[key] = value
    }
    return environment
  }
}
