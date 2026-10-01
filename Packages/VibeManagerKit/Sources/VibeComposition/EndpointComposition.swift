import Foundation
import VibeAgents
import VibeApplication
import VibeDomain
import VibeEndpoints
import VibePersistence
import VibeTerminal

/// The gateway of #107 as a program of the application's binary:
/// `Vibe Manager --endpoint-gateway <directory> --endpoints <file> --keychain-service <service>`.
///
/// Started detached by the application when a session on an endpoint needs it, it outlives the
/// application as long as a session token is left, and stops by itself after. Never returns.
public enum EndpointGatewayCommand {
  public static let endpointsArgument = "--endpoints"
  public static let keychainArgument = "--keychain-service"

  public static func runIfRequested(arguments: [String] = CommandLine.arguments) {
    guard let flag = arguments.firstIndex(of: EndpointGatewayService.argument),
      flag + 1 < arguments.count
    else { return }
    let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    let endpoints =
      value(after: endpointsArgument, in: arguments).map { URL(fileURLWithPath: $0) }
      ?? directory.deletingLastPathComponent().appendingPathComponent("endpoints.json")
    let service =
      value(after: keychainArgument, in: arguments) ?? KeychainEndpointSecretStore.defaultService
    let secrets = KeychainEndpointSecretStore(service: service)
    let location = GatewayLocation(directory: directory, endpointsURL: endpoints)
    let router = FileGatewayRouter(
      location: location,
      readEndpoints: { try FileEndpointRepository.read($0) },
      secret: { (try? secrets.secret(for: $0)) ?? nil })
    let finished = DispatchSemaphore(value: 0)
    Task.detached {
      _ = try? await EndpointGatewayService.run(location: location, router: router)
      finished.signal()
    }
    finished.wait()
    exit(0)
  }

  private static func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }
}

/// The gateway's controller, behind the application's port.
struct EndpointGatewayAdapter: EndpointGatewayControlling {
  let controller: EndpointGatewayController

  func ensureRunning() async throws -> URL {
    do {
      return try await controller.ensureRunning()
    } catch {
      throw EndpointGatewayError.couldNotStart(reason: String(describing: error))
    }
  }

  func register(token: String, endpoint: EndpointID, model: String, session: SessionID?)
    async throws
  {
    do {
      try await controller.register(
        token: token, endpoint: endpoint, model: model, session: session)
    } catch {
      throw EndpointGatewayError.routesNotWritable(reason: error.localizedDescription)
    }
  }

  func retain(sessions: Set<SessionID>) async throws {
    try await controller.retain(sessions: sessions)
  }
}

/// The endpoints as agents: read from their file, registered beside the command line agents, and
/// registered again each time they are saved.
@MainActor
public final class EndpointCatalog {
  let repository: any EndpointRepository
  let secrets: any EndpointSecretStore
  private let registry: AgentProviderRegistry
  private let gateway: any EndpointGatewayControlling
  private let providers: [any AgentProvider]
  private let gatewayDirectory: URL?

  init(
    repository: any EndpointRepository, secrets: any EndpointSecretStore,
    registry: AgentProviderRegistry, gateway: any EndpointGatewayControlling,
    providers: [any AgentProvider], gatewayDirectory: URL? = nil
  ) {
    self.gatewayDirectory = gatewayDirectory
    self.repository = repository
    self.secrets = secrets
    self.registry = registry
    self.gateway = gateway
    self.providers = providers
  }

  /// Reads the endpoints and registers them. An unreadable file registers none, and the settings
  /// say why.
  public func reload() async {
    let endpoints = (try? await repository.endpoints()) ?? []
    await registry.replaceEndpoints(
      Self.providers(
        for: endpoints, among: providers, gateway: gateway, secrets: secrets,
        gatewayDirectory: gatewayDirectory))
  }

  /// The providers of `endpoints`, driven by the Claude Code and Codex of `providers`. None when
  /// neither is there: the mock agents of the tests drive no endpoint.
  static func providers(
    for endpoints: [Endpoint], among providers: [any AgentProvider],
    gateway: any EndpointGatewayControlling, secrets: any EndpointSecretStore,
    gatewayDirectory: URL?
  ) -> [any AgentProvider] {
    guard let claudeCode = providers.lazy.compactMap({ $0 as? ClaudeCodeAgentProvider }).first,
      let codex = providers.lazy.compactMap({ $0 as? CodexAgentProvider }).first
    else { return [] }
    return endpoints.map {
      EndpointAgentProvider.make(
        endpoint: $0, claudeCode: claudeCode, codex: codex, gateway: gateway, secrets: secrets,
        gatewayDirectory: gatewayDirectory)
    }
  }

  /// Forgets the tokens of the sessions no longer running, so the gateway can stop once none is,
  /// and starts it again when some are left: a gateway that died while the application was away
  /// would leave the agents the terminal host kept talking to nobody.
  func retainActive(in sessions: [WorkSession]) async {
    let active = Set(sessions.filter { $0.status == .active }.map(\.id))
    try? await gateway.retain(sessions: active)
    let endpointSessions = sessions.filter {
      $0.status == .active && $0.agent.map { AgentProviderID($0.providerID).isEndpoint } == true
    }
    if !endpointSessions.isEmpty { _ = try? await gateway.ensureRunning() }
  }
}

extension AppEnvironment {
  static func gatewayLocation(dataFolder: URL, endpoints: URL) -> GatewayLocation {
    GatewayLocation(
      directory: dataFolder.appendingPathComponent("Gateway", isDirectory: true),
      endpointsURL: endpoints)
  }

  /// The keychain service of this copy: an isolated copy keeps its secrets apart.
  static func keychainService(isolated: Bool) -> String {
    isolated
      ? KeychainEndpointSecretStore.defaultService + ".isolated"
      : KeychainEndpointSecretStore.defaultService
  }

  /// Starts the gateway from the application's own binary. Outside an application bundle — a test
  /// runner — there is none to start, and the gateway says it could not start.
  static func gatewayLaunch(location: GatewayLocation, keychainService: String)
    -> @Sendable () throws -> Void
  {
    let executable = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.executableURL : nil
    return {
      guard let executable else { throw EndpointGatewayController.ControlError.didNotStart }
      let pid = try DetachedProcess.spawn(
        executableURL: executable,
        arguments: [
          EndpointGatewayService.argument, location.directory.path,
          EndpointGatewayCommand.endpointsArgument, location.endpointsURL.path,
          EndpointGatewayCommand.keychainArgument, keychainService,
        ],
        environment: DetachedProcess.minimalEnvironment())
      DetachedProcess.reap(pid)
    }
  }
}
