import Foundation
import Testing
import VibeApplication

@testable import VibePersistence

@Suite("The sites always allowed in the web view, where no script can add one (#239)")
@MainActor
struct BrowserGrantStoreTests {
  @Test("A site allowed or revoked is kept in the vault, and read back at the next launch")
  func keptInTheVault() {
    let vault = InMemoryBrowserGrantVault()
    let store = VaultBrowserPermissionStore(vault: vault)
    store.grant("https://github.com")
    store.grant("https://gitlab.com")
    store.revoke("https://gitlab.com")

    let relaunched = VaultBrowserPermissionStore(vault: vault)
    #expect(relaunched.grants == ["https://github.com"])
  }

  @Test("A site written into the user defaults, as `defaults write` would, is not allowed")
  func defaultsWriteIsIgnored() throws {
    let suite = "BrowserGrantStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    defaults.set(["https://github.com"], forKey: VaultBrowserPermissionStore.legacyDefaultsKey)

    let store = VaultBrowserPermissionStore(
      vault: InMemoryBrowserGrantVault(), legacyDefaults: defaults)
    #expect(store.grants.isEmpty)
    #expect(
      BrowserActionPolicy.decide(
        .act, url: URL(string: "https://github.com/settings/tokens"), grants: store.grants)
        == .ask)
    // The old list is gone, not merely skipped.
    #expect(defaults.object(forKey: VaultBrowserPermissionStore.legacyDefaultsKey) == nil)
  }

  @Test("A vault that cannot be read allows no site: every question is asked")
  func unreadableVault() {
    let store = VaultBrowserPermissionStore(
      vault: InMemoryBrowserGrantVault(failure: KeychainError(status: errSecAuthFailed)))
    #expect(store.grants.isEmpty)
    // An answer given now holds for this run.
    store.grant("https://github.com")
    #expect(store.grants == ["https://github.com"])
  }

  @Test("A vault holding anything but a list of sites allows none")
  func garbledVault() {
    let store = VaultBrowserPermissionStore(
      vault: InMemoryBrowserGrantVault(data: Data("not json".utf8)))
    #expect(store.grants.isEmpty)
  }
}
