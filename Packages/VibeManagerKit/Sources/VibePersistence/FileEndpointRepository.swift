import Foundation
import Security
import VibeApplication
import VibeDomain

/// The endpoints (#107), in `endpoints.json` next to `sessions.json`.
///
/// Read by the application and by the gateway, which runs in a process of its own. A file that
/// cannot be read, or that a newer version wrote, is never written over. Secrets are not in it.
public actor FileEndpointRepository: EndpointRepository {
  static let schema = 1

  private let storeURL: URL

  public init(storeURL: URL = FileEndpointRepository.defaultStoreURL()) {
    self.storeURL = storeURL
  }

  public static func defaultStoreURL() -> URL {
    FileSessionRepository.defaultStoreURL().deletingLastPathComponent()
      .appendingPathComponent("endpoints.json", isDirectory: false)
  }

  public nonisolated var fileURL: URL? { storeURL }

  struct Stored: Codable {
    var schema: Int
    var endpoints: [Endpoint]
  }

  public func endpoints() throws -> [Endpoint] {
    try Self.read(storeURL)
  }

  /// Also used by the gateway, which has no actor of its own for the file.
  public static func read(_ url: URL) throws -> [Endpoint] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw EndpointStoreError.unreadable(reason: error.localizedDescription)
    }
    guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
      throw EndpointStoreError.unreadable(
        reason: String(localized: "the file is damaged.", bundle: .module))
    }
    guard stored.schema <= schema else {
      throw EndpointStoreError.unreadable(
        reason: String(
          localized: "the file was written by a newer version of Vibe Manager.", bundle: .module))
    }
    return stored.endpoints
  }

  public func save(_ endpoints: [Endpoint]) throws {
    // Refused over a file that cannot be read: its bytes would be lost.
    _ = try self.endpoints()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    do {
      let data = try encoder.encode(Stored(schema: Self.schema, endpoints: endpoints))
      try AtomicFileWriter.write(data, to: storeURL)
    } catch {
      throw EndpointStoreError.cannotWrite(reason: error.localizedDescription)
    }
  }
}

/// The secrets of the endpoints, in the login keychain.
///
/// One generic password per endpoint, under the service below and the endpoint's identifier:
/// readable after the first unlock of the session, never synchronised to other Macs. The
/// application writes them; the gateway, the same binary in another process, reads them.
public struct KeychainEndpointSecretStore: EndpointSecretStore {
  public static let defaultService = "com.hadrienl.VibeManager.endpoint"

  private let service: String

  /// `service` apart for tests and for isolated copies of the application, which must not see
  /// the secrets of the one the user works in.
  public init(service: String = KeychainEndpointSecretStore.defaultService) {
    self.service = service
  }

  private func query(for endpoint: EndpointID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: endpoint.rawValue.uuidString,
      kSecUseDataProtectionKeychain as String: false,
    ]
  }

  public func secret(for endpoint: EndpointID) throws -> String? {
    var query = query(for: endpoint)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else { return nil }
      return String(data: data, encoding: .utf8)
    case errSecItemNotFound:
      return nil
    default:
      throw EndpointSecretError.keychain(status: status)
    }
  }

  public func setSecret(_ secret: String, for endpoint: EndpointID) throws {
    let data = Data(secret.utf8)
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(query(for: endpoint) as CFDictionary, update as CFDictionary)
    switch status {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var item = query(for: endpoint)
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      item[kSecAttrLabel as String] = "Vibe Manager endpoint"
      let added = SecItemAdd(item as CFDictionary, nil)
      guard added == errSecSuccess else { throw EndpointSecretError.keychain(status: added) }
    default:
      throw EndpointSecretError.keychain(status: status)
    }
  }

  public func removeSecret(for endpoint: EndpointID) throws {
    let status = SecItemDelete(query(for: endpoint) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw EndpointSecretError.keychain(status: status)
    }
  }
}
