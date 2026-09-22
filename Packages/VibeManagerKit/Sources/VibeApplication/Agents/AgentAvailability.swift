import Foundation

/// Where an executable was found, so the diagnostic can explain why the application may see a
/// different binary than the user's terminal does.
public enum AgentDetectionSource: String, Hashable, Sendable {
  case userDefined
  case candidateDirectory
  case processPath
  case loginShell
}

public struct AgentInstallation: Hashable, Sendable {
  public let executablePath: String
  public let version: AgentVersion?
  public let rawVersionOutput: String?
  public let source: AgentDetectionSource
  public let detectedAt: Date

  public init(
    executablePath: String,
    version: AgentVersion?,
    rawVersionOutput: String? = nil,
    source: AgentDetectionSource,
    detectedAt: Date
  ) {
    self.executablePath = executablePath
    self.version = version
    self.rawVersionOutput = rawVersionOutput
    self.source = source
    self.detectedAt = detectedAt
  }

  public var executableURL: URL {
    URL(fileURLWithPath: executablePath)
  }
}

public enum AgentAvailabilityState: Hashable, Sendable {
  case available
  case outdated(found: AgentVersion, required: AgentVersion)
  case notFound
  case notExecutable
  case unauthenticated
  case probeFailed(reason: AgentProbeFailure)

  public var isUsable: Bool {
    switch self {
    case .available, .unauthenticated:
      // An unproven authentication must not prevent a launch: the CLI itself will ask.
      return true
    case .outdated, .notFound, .notExecutable, .probeFailed:
      return false
    }
  }
}

public enum AgentProbeFailure: Hashable, Sendable {
  case timedOut
  case failed(exitCode: Int32)
  case cancelled

  /// Whether the agent said nothing rather than said something wrong.
  ///
  /// A command that never answered and one that answered with an error deserve neither the same
  /// sentence nor the same lifetime in a cache: the first one is likely to work on the next
  /// attempt, the second one is not.
  public var isTransient: Bool {
    switch self {
    case .timedOut, .cancelled:
      return true
    case .failed:
      return false
    }
  }
}

public enum AgentRemediation: Hashable, Sendable, Identifiable {
  case install(documentationURL: URL?)
  case update(minimumVersion: AgentVersion, documentationURL: URL?)
  case authenticate(command: String?)
  case defineExecutablePath
  case retryDetection

  public var id: String {
    switch self {
    case .install: return "install"
    case .update: return "update"
    case .authenticate: return "authenticate"
    case .defineExecutablePath: return "defineExecutablePath"
    case .retryDetection: return "retryDetection"
    }
  }
}

/// A user presentable explanation of a provider state.
///
/// `summary` is safe to display anywhere. `detail` carries technical context and is only meant
/// for an explicit export. Neither ever contains a prompt, a token or an environment dump.
public struct AgentDiagnostic: Hashable, Sendable {
  public let providerID: AgentProviderID
  public let providerName: String
  public let state: AgentAvailabilityState
  public let summary: String
  public let detail: String?
  public let installation: AgentInstallation?
  public let probedAt: Date
  public let remediations: [AgentRemediation]

  public init(
    providerID: AgentProviderID,
    providerName: String,
    state: AgentAvailabilityState,
    summary: String,
    detail: String? = nil,
    installation: AgentInstallation? = nil,
    probedAt: Date,
    remediations: [AgentRemediation]
  ) {
    self.providerID = providerID
    self.providerName = providerName
    self.state = state
    self.summary = summary
    self.detail = detail
    self.installation = installation
    self.probedAt = probedAt
    self.remediations = remediations
  }

  /// A plain text report the user can copy into a bug report.
  ///
  /// Executable paths are reduced to their parent directory so the export never leaks a user
  /// name or a project layout.
  public func exportText() -> String {
    var lines = [
      "Provider: \(providerName) (\(providerID))",
      "State: \(Self.label(for: state))",
      "Summary: \(summary)",
    ]
    if let installation {
      lines.append("Executable directory: \(Self.redact(path: installation.executablePath))")
      lines.append(
        "Executable name: \(URL(fileURLWithPath: installation.executablePath).lastPathComponent)")
      lines.append("Detection source: \(installation.source.rawValue)")
      lines.append("Version: \(installation.version.map(String.init(describing:)) ?? "unknown")")
    }
    if let detail {
      lines.append("Detail: \(detail)")
    }
    lines.append("Probed at: \(ISO8601DateFormatter().string(from: probedAt))")
    return lines.joined(separator: "\n")
  }

  /// Reduces a path to its parent directory, with the home directory abbreviated.
  public static func redact(path: String) -> String {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let home = NSHomeDirectory()
    guard !home.isEmpty, directory.hasPrefix(home) else { return directory }
    return "~" + directory.dropFirst(home.count)
  }

  private static func label(for state: AgentAvailabilityState) -> String {
    switch state {
    case .available: return "available"
    case .outdated(let found, let required): return "outdated (\(found) < \(required))"
    case .notFound: return "not found"
    case .notExecutable: return "not executable"
    case .unauthenticated: return "not authenticated"
    case .probeFailed(let reason): return "probe failed (\(reason))"
    }
  }
}

public struct AgentAvailability: Hashable, Sendable {
  public let state: AgentAvailabilityState
  public let installation: AgentInstallation?
  public let diagnostic: AgentDiagnostic

  public init(
    state: AgentAvailabilityState,
    installation: AgentInstallation?,
    diagnostic: AgentDiagnostic
  ) {
    self.state = state
    self.installation = installation
    self.diagnostic = diagnostic
  }

  public var isUsable: Bool {
    state.isUsable
  }
}
