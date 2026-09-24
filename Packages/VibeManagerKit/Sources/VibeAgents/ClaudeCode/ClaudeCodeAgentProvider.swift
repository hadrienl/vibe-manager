import Foundation
import VibeApplication
import VibeDomain

public struct ClaudeCodeAgentProvider: AgentProvider {
  public static let id = AgentProviderID("claude-code")

  /// The series that was verified: `--session-id`, `--resume <uuid>`, `--model` and
  /// `auth status --json` were all exercised against `2.1.278`. Older releases may well work,
  /// but `auth status` is recent enough that a CLI without it would answer the probe with a
  /// usage error, and the agent would be reported signed out for good.
  public static let minimumVersion = AgentVersion(major: 2, minor: 1, patch: 0)

  public static let descriptor = AgentDescriptor(
    id: ClaudeCodeAgentProvider.id,
    displayName: "Claude Code",
    symbolName: "asterisk",
    minimumVersion: ClaudeCodeAgentProvider.minimumVersion,
    capabilities: AgentCapabilities(
      supportsModelSelection: true,
      supportsInitialPrompt: true,
      supportsResume: true,
      reportsUsage: true
    )
  )

  public static let specification = CommandLineAgentSpecification(
    binaryName: "claude",
    candidateDirectories: CommandLineAgentSpecification.defaultCandidateDirectories
      + ["~/.claude/local", "~/.claude/bin"],
    versionArguments: ["--version"],
    versionTimeout: .seconds(5),
    authenticationArguments: ["auth", "status", "--json"],
    additionalEnvironmentKeys: [
      "CLAUDE_CONFIG_DIR", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
      "http_proxy", "https_proxy", "no_proxy",
      "SSL_CERT_FILE", "SSL_CERT_DIR",
    ],
    documentationURL: URL(string: "https://docs.claude.com/en/docs/claude-code/setup"),
    authenticationCommandLine: "claude auth login",
    authenticationOutcome: ClaudeCodeAuthenticationStatus.isSignedIn
  )

  private let base: CommandLineAgentProvider
  private let catalog: any ClaudeCodeModelCatalogSource

  public init(base: CommandLineAgentProvider, catalog: any ClaudeCodeModelCatalogSource) {
    self.base = base
    self.catalog = catalog
  }

  public static func make(
    environment rawEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    diagnostics: any DiagnosticLog = NullDiagnosticLog()
  ) -> ClaudeCodeAgentProvider {
    // The CLI and the catalog reader must agree on where the configuration lives, so a value
    // that cannot be resolved into an absolute path is dropped rather than forwarded.
    let environment = ClaudeCodeHome.sanitized(environment: rawEnvironment)
    let probe = SystemProcessProbe()
    let locator = FileSystemExecutableLocator(environment: environment, probe: probe)
    let availabilityProbe = AgentAvailabilityProbe(
      descriptor: descriptor,
      specification: specification,
      locator: locator,
      probe: probe,
      environment: environment,
      diagnostics: diagnostics
    )

    return ClaudeCodeAgentProvider(
      base: CommandLineAgentProvider(
        descriptor: descriptor,
        specification: specification,
        models: [],
        argumentBuilder: ClaudeCodeArgumentBuilder(),
        availabilityProbe: availabilityProbe,
        environment: environment
      ),
      catalog: ClaudeCodeModelCatalog(environment: environment)
    )
  }

  /// The seam #7 will use: the plan names the conversation, this keeps that name.
  public func identifierCapture(
    for sessionID: SessionID,
    repository: any SessionRepository,
    transcripts: any ClaudeCodeTranscriptWatching = ClaudeCodeTranscriptWatcher(),
    transcriptTimeout: Duration = ClaudeCodeSessionIdentifierCapture.defaultTranscriptTimeout,
    persistenceWindow: Duration = ClaudeCodeSessionIdentifierCapture.defaultPersistenceWindow
  ) -> ClaudeCodeSessionIdentifierCapture {
    ClaudeCodeSessionIdentifierCapture(
      sessionID: sessionID,
      record: RecordAgentResumeIdentifier(
        repository: repository, providerID: Self.id.rawValue, launchedAt: Date()),
      transcripts: transcripts,
      transcriptTimeout: transcriptTimeout,
      persistenceWindow: persistenceWindow
    )
  }

  public var descriptor: AgentDescriptor {
    base.descriptor
  }

  public func availability(forceRefresh: Bool) async -> AgentAvailability {
    await base.availability(forceRefresh: forceRefresh)
  }

  public func models() async -> [AgentModel] {
    await catalog.models()
  }

  public func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    try await base.launchPlan(for: request)
  }
}
