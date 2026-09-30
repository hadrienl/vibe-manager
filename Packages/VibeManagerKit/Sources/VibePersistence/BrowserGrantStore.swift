import Foundation
import Security
import VibeApplication

/// Where the sites always allowed in the web view are kept (#239): somewhere the application alone
/// reads and writes.
public protocol BrowserGrantVault: Sendable {
  /// What was kept, `nil` when nothing was.
  func load() throws -> Data?
  func save(_ data: Data) throws
}

/// The sites as one item of the user's login keychain. An item the application created answers
/// the application only: any other program — `security` typed in an agent's terminal included —
/// makes macOS ask the user first. The user defaults, which any process of the user can write with
/// `defaults write`, are never read for them.
public struct KeychainBrowserGrantVault: BrowserGrantVault {
  public let service: String
  /// One item per copy: an isolated copy keeps sites of its own.
  public let account: String

  public init(service: String, account: String) {
    self.service = service
    self.account = account
  }

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  public func load() throws -> Data? {
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    switch status {
    case errSecSuccess: return result as? Data
    case errSecItemNotFound: return nil
    default: throw KeychainError(status: status)
    }
  }

  public func save(_ data: Data) throws {
    let update = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    guard update == errSecItemNotFound else {
      guard update == errSecSuccess else { throw KeychainError(status: update) }
      return
    }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrLabel as String] = "Vibe Manager — sites always allowed in the web view"
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    let added = SecItemAdd(item as CFDictionary, nil)
    guard added == errSecSuccess else { throw KeychainError(status: added) }
  }
}

public struct KeychainError: Error, Equatable, Sendable {
  public let status: OSStatus
}

/// A vault in memory, for tests and previews.
public final class InMemoryBrowserGrantVault: BrowserGrantVault, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  private let failure: (any Error)?

  public init(data: Data? = nil, failure: (any Error)? = nil) {
    self.data = data
    self.failure = failure
  }

  public func load() throws -> Data? {
    if let failure { throw failure }
    return lock.withLock { data }
  }

  public func save(_ data: Data) throws {
    if let failure { throw failure }
    lock.withLock { self.data = data }
  }
}

/// The sites where an agent may act, and read, without asking (#69, #239), kept in a vault.
///
/// Read once, when the application starts; written at each change. A vault that cannot be read
/// gives no site: the questions are asked, never skipped. The list the user defaults used to hold
/// is forgotten, not carried over: a site written there by the user and one written by a script
/// cannot be told apart.
@MainActor
public final class VaultBrowserPermissionStore: BrowserPermissionStore {
  /// Where the sites were kept before #239.
  public static let legacyDefaultsKey = "browser.alwaysAllowedSites.v1"

  public private(set) var grants: Set<String>
  private let vault: any BrowserGrantVault

  public init(vault: any BrowserGrantVault, legacyDefaults: UserDefaults? = nil) {
    self.vault = vault
    legacyDefaults?.removeObject(forKey: Self.legacyDefaultsKey)
    let data = try? vault.load()
    let sites = data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    grants = Set(sites)
  }

  public func grant(_ key: String) {
    grants.insert(key)
    save()
  }

  public func revoke(_ key: String) {
    grants.remove(key)
    save()
  }

  /// What cannot be written stays for this run: the answer the user just gave holds until the
  /// application quits, and is asked again after.
  private func save() {
    guard let data = try? JSONEncoder().encode(grants.sorted()) else { return }
    try? vault.save(data)
  }
}
