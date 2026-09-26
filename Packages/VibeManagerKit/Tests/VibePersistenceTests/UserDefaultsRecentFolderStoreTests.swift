import Foundation
import Testing
import VibeApplication

@testable import VibePersistence

@Suite("The recent folders preference")
struct UserDefaultsRecentFolderStoreTests {
  private let key = "newSession.recentFolders.v1"

  private func suiteName() -> String {
    "vibe.manager.tests.\(UUID().uuidString)"
  }

  @Test("What was saved is what comes back, after a relaunch too")
  func roundTrip() async {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let folders = RecentFolders([
      RecentFolder(path: "/code/api", key: "/code/api"),
      RecentFolder(path: "/var/x", key: "/private/var/x"),
    ])

    await UserDefaultsRecentFolderStore(suiteName: suite).save(folders)

    #expect(await UserDefaultsRecentFolderStore(suiteName: suite).load() == folders)
  }

  @Test("Never written reads as nothing, written empty as an empty history")
  func neverWrittenIsNotEmpty() async {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let store = UserDefaultsRecentFolderStore(suiteName: suite)

    #expect(await store.load() == nil)
    await store.save(RecentFolders())
    #expect(await store.load() == RecentFolders())
  }

  @Test("An unreadable preference is an empty history, not an error")
  func corruptedPreferenceIsEmpty() async throws {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(Data("not json".utf8), forKey: key)

    #expect(await UserDefaultsRecentFolderStore(suiteName: suite).load() == RecentFolders())
  }

  @Test("An entry that cannot be read is dropped, and the others kept")
  func unreadableEntryIsDropped() async throws {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let defaults = try #require(UserDefaults(suiteName: suite))
    let json = """
      [{"path":"/a","key":"/a"},{"path":42},"nonsense",{"path":"/b","key":"/b"}]
      """
    defaults.set(Data(json.utf8), forKey: key)

    let loaded = await UserDefaultsRecentFolderStore(suiteName: suite).load()

    #expect(loaded?.entries.map(\.path) == ["/a", "/b"])
  }

  @Test("A history edited beyond the limit is read back within it")
  func oversizedHistoryIsBounded() async throws {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let defaults = try #require(UserDefaults(suiteName: suite))
    let entries = (0..<25).map { "{\"path\":\"/f\($0)\",\"key\":\"/f\($0)\"}" }
    defaults.set(Data("[\(entries.joined(separator: ","))]".utf8), forKey: key)

    let loaded = await UserDefaultsRecentFolderStore(suiteName: suite).load()

    #expect(loaded?.entries.count == RecentFolders.limit)
    #expect(loaded?.entries.first?.path == "/f0")
  }
}
