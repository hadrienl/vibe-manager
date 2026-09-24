import Foundation
import VibeApplication
import VibeDomain

/// The Codex CLI, driven as the interactive terminal user interface it is meant to be.
///
/// Detection, caching, version comparison and diagnostics all come from the shared command
/// line provider: this type only declares what is specific to `codex` — how it is found, how
/// its arguments are shaped, and where its model list comes from.
public struct CodexAgentProvider: AgentProvider {
  public static let id = AgentProviderID("codex")

  /// The oldest release series this provider was verified against.
  ///
  /// Only three pieces of the CLI surface are used — `-m`, `-C/--cd` and
  /// `resume <SESSION_ID>` — and they were checked on `codex-cli 0.153.2`. Older releases very
  /// probably work too, but "probably" is not a contract: an installation below this floor is
  /// reported as outdated, with an update remediation, rather than launched into an unverified
  /// command line.
  public static let minimumVersion = AgentVersion(major: 0, minor: 153, patch: 0)

  public static let descriptor = AgentDescriptor(
    id: CodexAgentProvider.id,
    displayName: "Codex",
    symbolName: "chevron.left.forwardslash.chevron.right",
    minimumVersion: CodexAgentProvider.minimumVersion,
    capabilities: AgentCapabilities(
      supportsModelSelection: true,
      supportsInitialPrompt: true,
      supportsResume: true,
      // #18 owns usage metrics; nothing is collected here.
      reportsUsage: false
    )
  )

  public static let specification = CommandLineAgentSpecification(
    binaryName: "codex",
    candidateDirectories: CommandLineAgentSpecification.defaultCandidateDirectories
      + ["~/.codex/bin"],
    versionArguments: ["--version"],
    versionTimeout: .seconds(5),
    // The exit code of `codex login status` is the only sign in signal used. No token,
    // `auth.json` or keychain item is ever read.
    authenticationArguments: ["login", "status"],
    // Proxy and certificate variables are forwarded because a corporate Mac without them
    // fails with a network error whose cause is nowhere near its message.
    additionalEnvironmentKeys: [
      "CODEX_HOME", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
      "http_proxy", "https_proxy", "no_proxy",
      "SSL_CERT_FILE", "SSL_CERT_DIR",
    ],
    documentationURL: URL(string: "https://developers.openai.com/codex/cli"),
    authenticationCommandLine: "codex login"
  )

  private let base: CommandLineAgentProvider
  private let catalog: any CodexModelCatalogSource
  private let discovery: any CodexSessionDiscovering

  public init(
    base: CommandLineAgentProvider,
    catalog: any CodexModelCatalogSource,
    discovery: any CodexSessionDiscovering
  ) {
    self.base = base
    self.catalog = catalog
    self.discovery = discovery
  }

  /// Wires the provider to the real file system, the real process probe and the user's
  /// `CODEX_HOME`. The only place that touches the machine.
  public static func make(
    environment rawEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) -> CodexAgentProvider {
    // A `CODEX_HOME` this application cannot resolve is dropped rather than forwarded: the
    // CLI would then write its sessions where nothing watches for them.
    let environment = CodexHome.sanitized(environment: rawEnvironment)
    let probe = SystemProcessProbe()
    let locator = FileSystemExecutableLocator(environment: environment, probe: probe)
    let availabilityProbe = AgentAvailabilityProbe(
      descriptor: descriptor,
      specification: specification,
      locator: locator,
      probe: probe,
      environment: environment
    )

    return CodexAgentProvider(
      base: CommandLineAgentProvider(
        descriptor: descriptor,
        specification: specification,
        // An empty catalog on purpose: see `models()`. The launch validation must not reject
        // a model slug just because the application does not know it yet.
        models: [],
        argumentBuilder: CodexArgumentBuilder(),
        availabilityProbe: availabilityProbe,
        environment: environment
      ),
      catalog: CodexModelCatalog(environment: environment),
      discovery: CodexRolloutSessionDiscovery(environment: environment)
    )
  }

  /// Builds the object that captures the resume identifier of one launch and stores it.
  ///
  /// The provider owns this because knowing where Codex records a session is knowledge about
  /// Codex, not about sessions: the caller that starts the terminal only has to forward the
  /// process lifetime and the decoded output.
  public func identifierCapture(
    for sessionID: SessionID,
    workingDirectoryPath: String,
    repository: any SessionRepository,
    timeout: Duration = CodexSessionIdentifierCapture.defaultTimeout
  ) -> CodexSessionIdentifierCapture {
    CodexSessionIdentifierCapture(
      sessionID: sessionID,
      workingDirectoryPath: workingDirectoryPath,
      discovery: discovery,
      record: RecordAgentResumeIdentifier(
        repository: repository, providerID: Self.id.rawValue, launchedAt: Date()),
      timeout: timeout
    )
  }

  public var descriptor: AgentDescriptor {
    base.descriptor
  }

  public func availability(forceRefresh: Bool) async -> AgentAvailability {
    await base.availability(forceRefresh: forceRefresh)
  }

  /// The catalog is advisory: it fills the model picker, it does not gate a launch.
  ///
  /// Codex resolves model names server side, and new ones appear between two releases of this
  /// application. Rejecting an unknown slug would make Vibe Manager expire faster than the CLI
  /// it drives, so only the shape of a slug is validated, never its membership.
  public func models() async -> [AgentModel] {
    await catalog.models()
  }

  public func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    try await base.launchPlan(for: request)
  }
}
