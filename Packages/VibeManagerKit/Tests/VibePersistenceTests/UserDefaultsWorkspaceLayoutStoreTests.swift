import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("The layout preference")
struct UserDefaultsWorkspaceLayoutStoreTests {
  private func suiteName() -> String {
    "vibe.manager.tests.\(UUID().uuidString)"
  }

  @Test("What was saved is what comes back")
  func roundTrip() async {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let store = UserDefaultsWorkspaceLayoutStore(suiteName: suite)
    let layout = WorkspaceLayout(
      selectedSessionID: SessionID(),
      isSidebarVisible: false,
      isInspectorVisible: true,
      sidebarWidth: 320,
      inspectorWidth: 300
    )

    await store.save(layout)

    #expect(await store.load() == layout)
    // A second store on the same suite reads it, which is what a relaunch does.
    #expect(await UserDefaultsWorkspaceLayoutStore(suiteName: suite).load() == layout)
  }

  @Test("Nothing stored yet opens the default workspace")
  func emptyStoreIsNotAFailure() async {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    #expect(await UserDefaultsWorkspaceLayoutStore(suiteName: suite).load() == WorkspaceLayout())
  }

  @Test("The filter comes back with the columns, minus the search that was in progress")
  func filterRoundTrip() async {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let store = UserDefaultsWorkspaceLayoutStore(suiteName: suite)
    let layout = WorkspaceLayout(
      sessionFilter: SessionFilter(
        scope: .closed,
        sort: .name,
        searchText: "half-typed query",
        agentProviderIDs: ["codex"],
        repositoryPath: "/work/api"
      )
    )

    await store.save(layout)
    let loaded = await UserDefaultsWorkspaceLayoutStore(suiteName: suite).load()

    #expect(loaded.sessionFilter.scope == .closed)
    #expect(loaded.sessionFilter.sort == .name)
    #expect(loaded.sessionFilter.agentProviderIDs == ["codex"])
    #expect(loaded.sessionFilter.repositoryPath == "/work/api")
    // A query typed days ago would read as an empty store rather than as a filter.
    #expect(loaded.sessionFilter.searchText.isEmpty)
  }

  @Test("A layout written before filters existed opens the default view")
  func layoutWithoutFilterFallsBack() async {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let legacy = Data(#"{"isSidebarVisible":true,"isInspectorVisible":false}"#.utf8)
    UserDefaults(suiteName: suite)?.set(legacy, forKey: "workspace.layout.v1")

    let loaded = await UserDefaultsWorkspaceLayoutStore(suiteName: suite).load()

    #expect(loaded.isInspectorVisible == false)
    #expect(loaded.sessionFilter == SessionFilter())
  }

  @Test("A preference written by something else is ignored, not obeyed")
  func corruptedPreferenceFallsBack() async {
    let suite = suiteName()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    UserDefaults(suiteName: suite)?.set(Data("not a layout".utf8), forKey: "workspace.layout.v1")

    let loaded = await UserDefaultsWorkspaceLayoutStore(suiteName: suite).load()

    #expect(loaded == WorkspaceLayout())
  }
}
