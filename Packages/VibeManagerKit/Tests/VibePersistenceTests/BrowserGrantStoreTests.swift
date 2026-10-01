import Foundation
import Testing
import VibeApplication

@testable import VibePersistence

@Suite("The sites always allowed in the web view, where no script can add one (#239)")
@MainActor
struct BrowserGrantStoreTests {
  @Test("A site allowed or revoked is kept in the vault, and read back at the next launch")
  func keptInTheVault() async {
    let vault = InMemoryBrowserGrantVault()
    let store = VaultBrowserPermissionStore(vault: vault)
    await store.loaded()
    store.grant("https://github.com")
    store.grant("https://gitlab.com")
    store.revoke("https://gitlab.com")

    let relaunched = VaultBrowserPermissionStore(vault: vault)
    await relaunched.loaded()
    #expect(relaunched.grants == ["https://github.com"])
  }

  @Test("A site written into the user defaults, as `defaults write` would, is not allowed")
  func defaultsWriteIsIgnored() async throws {
    let suite = "BrowserGrantStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    defaults.set(["https://github.com"], forKey: VaultBrowserPermissionStore.legacyDefaultsKey)

    let store = VaultBrowserPermissionStore(
      vault: InMemoryBrowserGrantVault(), legacyDefaults: defaults)
    await store.loaded()
    #expect(store.grants.isEmpty)
    #expect(
      BrowserActionPolicy.decide(
        .act, url: URL(string: "https://github.com/settings/tokens"), grants: store.grants)
        == .ask)
    // The old list is gone, not merely skipped.
    #expect(defaults.object(forKey: VaultBrowserPermissionStore.legacyDefaultsKey) == nil)
  }

  @Test("A vault that cannot be read allows no site, and is never written over")
  func unreadableVault() async {
    let log = RecordingDiagnosticLog()
    let store = VaultBrowserPermissionStore(
      vault: InMemoryBrowserGrantVault(failure: KeychainError(status: errSecAuthFailed)), log: log)
    await store.loaded()
    #expect(store.grants.isEmpty)
    #expect(log.names == ["browser.grants.unreadable"])
    // An answer given now holds for this run only.
    store.grant("https://github.com")
    #expect(store.grants == ["https://github.com"])
  }

  @Test("An item that is not the application's allows no site, and is not written over")
  func foreignItemKept() async {
    let vault = InMemoryBrowserGrantVault(content: .foreignItem)
    let log = RecordingDiagnosticLog()
    let store = VaultBrowserPermissionStore(vault: vault, log: log)
    await store.loaded()
    #expect(store.grants.isEmpty)
    store.grant("https://github.com")
    #expect(vault.saved == nil)
    #expect(log.names == ["browser.grants.foreignItem"])
  }

  @Test("A site allowed before the vault is read is kept with what the vault held")
  func grantedWhileLoading() async throws {
    let vault = InMemoryBrowserGrantVault(content: .sites(Data(#"["https://gitlab.com"]"#.utf8)))
    let store = VaultBrowserPermissionStore(vault: vault)
    store.grant("https://github.com")
    await store.loaded()
    #expect(store.grants == ["https://github.com", "https://gitlab.com"])
    let saved = try JSONDecoder().decode([String].self, from: try #require(vault.saved))
    #expect(saved == ["https://github.com", "https://gitlab.com"])
  }

  @Test("A vault holding anything but a list of sites allows none")
  func garbledVault() async {
    let store = VaultBrowserPermissionStore(
      vault: InMemoryBrowserGrantVault(content: .sites(Data("not json".utf8))))
    await store.loaded()
    #expect(store.grants.isEmpty)
  }
}

/// The keychain itself, in a keychain file of the test's own: the user's login keychain is never
/// touched, and nothing is ever read from an item the test process does not own, so that macOS
/// never asks anything.
@Suite("The keychain trusts an item only when the application made it (#239)", .serialized)
@MainActor
struct KeychainBrowserGrantVaultTests {
  private static let service = "eu.hadrien.VibeManager.tests.browser-grants"

  private func withKeychain(_ body: (String) async throws -> Void) async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("grant-keychain-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = folder.appendingPathComponent("test.keychain-db").path
    defer {
      _ = try? Self.security(["delete-keychain", path])
      try? FileManager.default.removeItem(at: folder)
    }
    try Self.security(["create-keychain", "-p", "test", path])
    try Self.security(["unlock-keychain", "-p", "test", path])
    try await body(path)
  }

  @discardableResult
  private static func security(_ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw KeychainError(status: OSStatus(process.terminationStatus))
    }
    return process.terminationStatus
  }

  @Test("The application's own item is made at the first launch, then kept")
  func madeAtFirstLaunch() async throws {
    try await withKeychain { path in
      let vault = try #require(
        KeychainBrowserGrantVault(service: Self.service, account: "own", keychainPath: path))
      #expect(try vault.open() == .sites(Data("[]".utf8)))
      try vault.save(Data(#"["https://github.com"]"#.utf8))
      #expect(try vault.open() == .sites(Data(#"["https://github.com"]"#.utf8)))
    }
  }

  @Test(
    "An item a script made first — open to every program, or naming another — allows nothing",
    arguments: [["-A"], ["-T", "/usr/bin/true"]])
  func scriptMadeItem(access: [String]) async throws {
    try await withKeychain { path in
      try Self.security(
        ["add-generic-password", "-s", Self.service, "-a", "forged"] + access
          + ["-w", #"["https://github.com"]"#, path])
      let vault = try #require(
        KeychainBrowserGrantVault(service: Self.service, account: "forged", keychainPath: path))
      let log = RecordingDiagnosticLog()
      let store = VaultBrowserPermissionStore(vault: vault, log: log)
      await store.loaded()
      #expect(store.grants.isEmpty)
      #expect(log.names == ["browser.grants.foreignItem"])
      // Replaced by the application's own, empty: the next launch reads it without a question.
      #expect(try vault.open() == .sites(Data("[]".utf8)))
    }
  }
}
