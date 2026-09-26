import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Remembering the folders sessions are created in")
struct RecentFolderHistoryTests {
  private func session(in folder: String, createdAt seconds: TimeInterval = 1_699_000_000)
    -> WorkSession
  {
    SessionDraft(
      name: "Session", initialPrompt: "", providerID: "stub", workingDirectoryPath: folder
    ).session(createdAt: Date(timeIntervalSince1970: seconds))
  }

  private func plan(_ folder: String) -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: AgentProviderID("stub"), executablePath: "/usr/bin/true", arguments: [],
      environment: [:], workingDirectoryPath: folder, promptDelivery: .none)
  }

  @Test("An installation that never kept any starts from the folders of its sessions")
  func seededFromTheSessions() async {
    let store = InMemoryRecentFolderStore()
    let model = AppModel(
      repository: HistoryRepository(values: [
        session(in: "/work/old", createdAt: 1), session(in: "/work/new", createdAt: 2),
      ]),
      recentFolderStore: store)

    await model.load()

    #expect(model.recentFolders.entries.map(\.path) == ["/work/new", "/work/old"])
    #expect(await store.load() == model.recentFolders)
  }

  @Test("A history already written is read as it is, even empty")
  func storedHistoryIsNotReseeded() async {
    let store = InMemoryRecentFolderStore(RecentFolders())
    let model = AppModel(
      repository: HistoryRepository(values: [session(in: "/work/api")]),
      recentFolderStore: store)

    await model.load()

    #expect(model.recentFolders.entries.isEmpty)
  }

  @Test("Creating a session puts its folder first, launched or left in To Do")
  func creationRecordsTheFolder() async throws {
    let first = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    ).path
    let second = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    ).path
    for path in [first, second] {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    defer {
      for path in [first, second] { try? FileManager.default.removeItem(atPath: path) }
    }
    let store = InMemoryRecentFolderStore()
    let model = AppModel(repository: HistoryRepository(values: []), recentFolderStore: store)
    await model.load()

    await model.complete(
      SessionCreation(session: session(in: first), plan: plan(first)), launching: false)
    await model.complete(
      SessionCreation(session: session(in: second), plan: plan(second)), launching: false)
    // `/var/folders/…` and `/private/var/folders/…` are one folder: no second entry.
    await model.complete(
      SessionCreation(
        session: session(in: CanonicalPath.of(first)), plan: plan(CanonicalPath.of(first))),
      launching: false)

    #expect(model.recentFolders.entries.map(\.path) == [CanonicalPath.of(first), second])
    #expect(model.recentFolders.entries.first?.key == CanonicalPath.of(first))
    #expect(await store.load() == model.recentFolders)
  }

  @Test("Cancelling the sheet remembers nothing")
  func cancellingRecordsNothing() async {
    let store = InMemoryRecentFolderStore(RecentFolders())
    let model = AppModel(repository: HistoryRepository(values: []), recentFolderStore: store)
    await model.load()

    model.cancelNewSession()

    #expect(await store.load() == RecentFolders())
  }

  @Test("Remove from Recents is kept for the next sheet")
  func forgettingIsStored() async throws {
    let store = InMemoryRecentFolderStore(RecentFolders(recent("/a", "/b")))
    let model = AppModel(repository: HistoryRepository(values: []), recentFolderStore: store)
    await model.load()

    model.forgetRecentFolder(RecentFolder(lexicalPath: "/a"))

    #expect(model.recentFolders.entries.map(\.path) == ["/b"])
    try await waitFor { await store.load()?.entries.map(\.path) == ["/b"] }
  }

  private func recent(_ paths: String...) -> [RecentFolder] {
    paths.map(RecentFolder.init(lexicalPath:))
  }

  private func waitFor(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The condition never held.")
  }
}

private actor HistoryRepository: SessionRepository {
  private let values: [WorkSession]

  init(values: [WorkSession]) {
    self.values = values
  }

  func sessions() -> [WorkSession] { values }

  func session(id: SessionID) -> WorkSession? {
    values.first { $0.id == id }
  }

  func save(_: WorkSession) {}
}
