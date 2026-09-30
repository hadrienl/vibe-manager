import Foundation
import VibeDomain

public enum EndpointStoreError: Error, Equatable, Sendable, LocalizedError {
  /// The file is there but could not be read, or was written by a newer version. It is never
  /// written over.
  case unreadable(reason: String)
  case cannotWrite(reason: String)

  public var errorDescription: String? {
    switch self {
    case .unreadable(let reason):
      return String(localized: "Endpoints couldn't be read: \(reason)", bundle: .module)
    case .cannotWrite(let reason):
      return String(localized: "Endpoints couldn't be saved: \(reason)", bundle: .module)
    }
  }
}

/// Where the endpoints are kept (#107). Their secrets are not: see `EndpointSecretStore`.
public protocol EndpointRepository: Sendable {
  /// In the user's order; empty when nothing was ever saved.
  func endpoints() async throws -> [Endpoint]
  func save(_ endpoints: [Endpoint]) async throws
  /// Where the file is, for Reveal in Finder. `nil`: nowhere on disk.
  var fileURL: URL? { get }
}

public actor InMemoryEndpointRepository: EndpointRepository {
  private var stored: [Endpoint]

  public init(endpoints: [Endpoint] = []) {
    stored = endpoints
  }

  public func endpoints() -> [Endpoint] { stored }
  public func save(_ endpoints: [Endpoint]) { stored = endpoints }
  public nonisolated var fileURL: URL? { nil }
}

public enum EndpointSecretError: Error, Equatable, Sendable, LocalizedError {
  /// The keychain refused, with its status code.
  case keychain(status: Int32)

  public var errorDescription: String? {
    switch self {
    case .keychain(let status):
      return String(
        localized: "The keychain refused to keep the secret (error \(String(status))).",
        bundle: .module)
    }
  }
}

/// The secrets of the endpoints: the keychain in the application, memory in tests.
///
/// A secret is written and deleted, never shown again: a form only learns whether there is one.
public protocol EndpointSecretStore: Sendable {
  func secret(for endpoint: EndpointID) throws -> String?
  func setSecret(_ secret: String, for endpoint: EndpointID) throws
  func removeSecret(for endpoint: EndpointID) throws
}

extension EndpointSecretStore {
  public func hasSecret(for endpoint: EndpointID) -> Bool {
    ((try? secret(for: endpoint)) ?? nil)?.isEmpty == false
  }
}

public final class InMemoryEndpointSecretStore: EndpointSecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var secrets: [EndpointID: String]

  public init(secrets: [EndpointID: String] = [:]) {
    self.secrets = secrets
  }

  public func secret(for endpoint: EndpointID) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return secrets[endpoint]
  }

  public func setSecret(_ secret: String, for endpoint: EndpointID) {
    lock.lock()
    secrets[endpoint] = secret
    lock.unlock()
  }

  public func removeSecret(for endpoint: EndpointID) {
    lock.lock()
    secrets[endpoint] = nil
    lock.unlock()
  }
}

/// The gateway, as the application sees it: running, and told which session tokens lead where.
public protocol EndpointGatewayControlling: Sendable {
  /// Starts the gateway if it is not running and returns its base URL, `http://127.0.0.1:<port>`.
  func ensureRunning() async throws -> URL
  /// Lets `token` through to `model` of `endpoint`, for the session `session`: a new launch of the
  /// same session replaces its previous token.
  func register(token: String, endpoint: EndpointID, model: String, session: SessionID?)
    async throws
  /// Forgets the tokens of the sessions no longer running. The gateway stops when none is left.
  func retain(sessions: Set<SessionID>) async throws
}

public enum EndpointGatewayError: Error, Equatable, Sendable, LocalizedError {
  case couldNotStart(reason: String)
  case routesNotWritable(reason: String)

  public var errorDescription: String? {
    switch self {
    case .couldNotStart(let reason):
      return String(localized: "The endpoint gateway couldn't start: \(reason)", bundle: .module)
    case .routesNotWritable(let reason):
      return String(
        localized: "The endpoint gateway couldn't be told about the session: \(reason)",
        bundle: .module)
    }
  }
}
