import Foundation
import Security
import VibeApplication

/// What a vault gives when it is opened.
public enum BrowserGrantVaultContent: Equatable, Sendable {
  /// The application's own item, and what it holds.
  case sites(Data)
  /// An item the application did not make was there: it was not read, and an empty one of the
  /// application's own now stands in its place.
  case replacedForeignItem
  /// An item the application did not make is there, and could not be removed: it was not read,
  /// and nothing may be written over it.
  case foreignItem
}

/// Where the sites always allowed in the web view are kept (#239): somewhere the application alone
/// reads and writes.
public protocol BrowserGrantVault: Sendable {
  /// Opens the vault, making the application's own item first when there is none.
  func open() throws -> BrowserGrantVaultContent
  func save(_ data: Data) throws
}

/// The sites as one item of a keychain — the user's login keychain in the application.
///
/// An item the application made answers the application only: its access list trusts it alone,
/// and any other program reading it makes macOS ask the user. The user defaults, which any process
/// of the user can write with `defaults write`, are never read for the sites.
///
/// A program of the user's can make such an item *before* the application does, with any access
/// list it likes: an item found is therefore read only when its access list trusts this
/// application alone. One that trusts every program, or another program, is not read, is removed,
/// and replaced by the application's own, empty. The item is made at the first launch, so that no
/// such window stays open. What the keychain cannot tell apart — an item made by another program
/// that names this application alone — is a limit written in ADR 0023: a process of the user's
/// reaches the web view's cookies too, and is out of what this guards.
/// A keychain reference is a thread-safe Core Foundation object: the vault is used from any thread.
public struct KeychainBrowserGrantVault: BrowserGrantVault, @unchecked Sendable {
  public let service: String
  /// One item per copy: an isolated copy keeps sites of its own.
  public let account: String
  /// `nil`: the default keychain, the user's login keychain. A test gives one of its own.
  private let keychain: SecKeychain?

  public init(service: String, account: String) {
    self.init(service: service, account: account, keychain: nil)
  }

  /// The item in the keychain file at `keychainPath`, already unlocked: a test's own.
  init?(service: String, account: String, keychainPath: String) {
    guard let keychain = LegacyKeychainAccess.current.keychain(at: keychainPath) else { return nil }
    self.init(service: service, account: account, keychain: keychain)
  }

  private init(service: String, account: String, keychain: SecKeychain?) {
    self.service = service
    self.account = account
    self.keychain = keychain
  }

  private var query: [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let keychain { query[kSecMatchSearchList as String] = [keychain] }
    return query
  }

  public func open() throws -> BrowserGrantVaultContent {
    // The item is looked at before anything is read from it: reading an item that does not trust
    // this application would make macOS ask the user.
    var lookup = query
    lookup[kSecReturnRef as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var found: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &found)
    switch status {
    case errSecItemNotFound:
      try add(Data("[]".utf8))
      return .sites(Data("[]".utf8))
    case errSecSuccess:
      break
    default:
      throw KeychainError(status: status)
    }
    let access = LegacyKeychainAccess.current
    guard let found, let item = access.item(found) else {
      throw KeychainError(status: errSecInvalidItemRef)
    }
    guard access.trustsThisApplicationAlone(item) else {
      guard access.delete(item) == errSecSuccess else { return .foreignItem }
      try add(Data("[]".utf8))
      return .replacedForeignItem
    }
    var read = query
    read[kSecReturnData as String] = true
    read[kSecMatchLimit as String] = kSecMatchLimitOne
    var data: CFTypeRef?
    let readStatus = SecItemCopyMatching(read as CFDictionary, &data)
    guard readStatus == errSecSuccess, let data = data as? Data else {
      throw KeychainError(status: readStatus)
    }
    return .sites(data)
  }

  public func save(_ data: Data) throws {
    let update = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    guard update == errSecItemNotFound else {
      guard update == errSecSuccess else { throw KeychainError(status: update) }
      return
    }
    try add(data)
  }

  /// A new item, whose access list trusts this application alone: the default for an item a
  /// program adds.
  private func add(_ data: Data) throws {
    var item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrLabel as String: "Vibe Manager — sites always allowed in the web view",
    ]
    if let keychain { item[kSecUseKeychain as String] = keychain }
    // No user presence asked at each read: the item holds site names, not a credential, and is read
    // once per launch; what guards it is its access list (ADR 0023).
    let added = SecItemAdd(item as CFDictionary, nil)

    guard added == errSecSuccess else { throw KeychainError(status: added) }
  }
}

public struct KeychainError: Error, Equatable, Sendable {
  public let status: OSStatus
}

/// The access list of a file-based keychain item, read with the only API that gives it — marked
/// deprecated since the data protection keychain, which needs an entitlement this application does
/// not have. Called through a protocol, so that the deprecation stays here and the package still
/// builds with its warnings as errors.
protocol KeychainAccessReading {
  func keychain(at path: String) -> SecKeychain?
  func item(_ reference: CFTypeRef) -> SecKeychainItem?
  func trustsThisApplicationAlone(_ item: SecKeychainItem) -> Bool
  func delete(_ item: SecKeychainItem) -> OSStatus
}

enum LegacyKeychainAccess {
  static var current: any KeychainAccessReading { FileKeychainAccess() }
}

private struct FileKeychainAccess: KeychainAccessReading {
  @available(macOS, deprecated: 10.10)
  func keychain(at path: String) -> SecKeychain? {
    var keychain: SecKeychain?
    guard SecKeychainOpen(path, &keychain) == errSecSuccess else { return nil }
    return keychain
  }

  @available(macOS, deprecated: 10.10)
  func item(_ reference: CFTypeRef) -> SecKeychainItem? {
    guard CFGetTypeID(reference) == SecKeychainItemGetTypeID() else { return nil }
    return unsafeDowncast(reference, to: SecKeychainItem.self)
  }

  /// Whether whoever may read the item's secret is this application, and nothing else: an item
  /// open to every program, or naming another, is not the application's own.
  @available(macOS, deprecated: 10.10)
  func trustsThisApplicationAlone(_ item: SecKeychainItem) -> Bool {
    var me: SecTrustedApplication?
    guard SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me,
      let myIdentity = Self.identity(of: me)
    else { return false }
    var access: SecAccess?
    guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else {
      return false
    }
    var list: CFArray?
    guard SecAccessCopyACLList(access, &list) == errSecSuccess,
      let entries = list as? [SecACL]
    else { return false }
    var guardsTheSecret = false
    for entry in entries {
      let authorizations = SecACLCopyAuthorizations(entry) as? [String] ?? []
      guard authorizations.contains(kSecACLAuthorizationDecrypt as String) else { continue }
      guardsTheSecret = true
      var applications: CFArray?
      var description: CFString?
      var prompt = SecKeychainPromptSelector()
      guard SecACLCopyContents(entry, &applications, &description, &prompt) == errSecSuccess,
        let trusted = applications as? [SecTrustedApplication], !trusted.isEmpty,
        trusted.allSatisfy({ Self.identity(of: $0) == myIdentity })
      else { return false }
    }
    return guardsTheSecret
  }

  @available(macOS, deprecated: 10.10)
  func delete(_ item: SecKeychainItem) -> OSStatus {
    SecKeychainItemDelete(item)
  }

  @available(macOS, deprecated: 10.10)
  private static func identity(of application: SecTrustedApplication) -> Data? {
    var data: CFData?
    guard SecTrustedApplicationCopyData(application, &data) == errSecSuccess else { return nil }
    return data as Data?
  }
}

/// A vault in memory, for tests and previews.
public final class InMemoryBrowserGrantVault: BrowserGrantVault, @unchecked Sendable {
  private let lock = NSLock()
  private var content: BrowserGrantVaultContent
  private let failure: (any Error)?

  public init(
    content: BrowserGrantVaultContent = .sites(Data("[]".utf8)), failure: (any Error)? = nil
  ) {
    self.content = content
    self.failure = failure
  }

  public var saved: Data? {
    lock.withLock {
      guard case .sites(let data) = content else { return nil }
      return data
    }
  }

  public func open() throws -> BrowserGrantVaultContent {
    if let failure { throw failure }
    return lock.withLock { content }
  }

  public func save(_ data: Data) throws {
    if let failure { throw failure }
    lock.withLock { content = .sites(data) }
  }
}

/// The sites where an agent may act, and read, without asking (#69, #239), kept in a vault.
///
/// The vault is read once, away from the main thread, when the application starts: until then,
/// and whenever it cannot be read, no site is allowed and the questions are asked. A vault that
/// could not be read, or whose item is not the application's, is never written over: what the user
/// allows meanwhile holds until the application quits. The list the user defaults used to hold is
/// forgotten, not carried over: a site written there by the user and one written by a script
/// cannot be told apart.
@MainActor
public final class VaultBrowserPermissionStore: BrowserPermissionStore {
  /// Where the sites were kept before #239.
  public static let legacyDefaultsKey = "browser.alwaysAllowedSites.v1"

  public private(set) var grants: Set<String> = []
  private let vault: any BrowserGrantVault
  private let log: any DiagnosticLog
  private var mayWrite = false
  private var isLoading = true
  private var changedWhileLoading = false
  private var loading: Task<Void, Never>?

  public init(
    vault: any BrowserGrantVault, legacyDefaults: UserDefaults? = nil,
    log: any DiagnosticLog = NullDiagnosticLog()
  ) {
    self.vault = vault
    self.log = log
    legacyDefaults?.removeObject(forKey: Self.legacyDefaultsKey)
    loading = Task { [weak self, vault] in
      let opened = await Task.detached { Result { try vault.open() } }.value
      self?.opened(opened)
    }
  }

  /// Waits for the vault to have been read.
  public func loaded() async {
    await loading?.value
  }

  public func grant(_ key: String) {
    grants.insert(key)
    changed()
  }

  public func revoke(_ key: String) {
    grants.remove(key)
    changed()
  }

  private func changed() {
    if isLoading {
      changedWhileLoading = true
    } else {
      save()
    }
  }

  private func opened(_ result: Result<BrowserGrantVaultContent, any Error>) {
    isLoading = false
    switch result {
    case .success(.sites(let data)):
      mayWrite = true
      let sites = (try? JSONDecoder().decode([String].self, from: data)) ?? []
      grants.formUnion(sites)
    case .success(.replacedForeignItem):
      mayWrite = true
      log.record(.store, .error, "browser.grants.foreignItem", ["replaced": .flag(true)])
    case .success(.foreignItem):
      log.record(.store, .error, "browser.grants.foreignItem", ["replaced": .flag(false)])
    case .failure(let error):
      let status = (error as? KeychainError)?.status ?? 0
      log.record(.store, .error, "browser.grants.unreadable", ["status": .code(status)])
    }
    if changedWhileLoading { save() }
  }

  private func save() {
    guard mayWrite, let data = try? JSONEncoder().encode(grants.sorted()) else { return }
    do {
      try vault.save(data)
    } catch {
      let status = (error as? KeychainError)?.status ?? 0
      log.record(.store, .error, "browser.grants.unwritable", ["status": .code(status)])
    }
  }
}
