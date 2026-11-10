import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Remembering the folders sessions are created in", .timeLimit(.minutes(2)))
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

  @Test("A store that could not be read seeds nothing, so a later launch still can")
  func unreadableStoreSeedsNothing() async {
    let store = InMemoryRecentFolderStore()
    let model = AppModel(repository: UnreadableRepository(), recentFolderStore: store)

    await model.load()

    #expect(model.recentFolders.entries.isEmpty)
    #expect(await store.load() == nil)
  }

  @Test("A session created while the store was unreadable waits for the seeding, then joins it")
  func creationBeforeSeedingKeepsTheSessionsFolders() async {
    let store = InMemoryRecentFolderStore()
    let repository = RecoveringRepository(values: [session(in: "/work/old", createdAt: 1)])
    let model = AppModel(repository: repository, recentFolderStore: store)
    await model.load()

    await model.complete(
      SessionCreation(session: session(in: "/work/new"), plan: plan("/work/new")),
      launching: false)
    // One folder written now would be the whole history for good.
    #expect(await store.load() == nil)

    await repository.recover()
    await model.reload()

    #expect(model.recentFolders.entries.map(\.path) == ["/work/new", "/work/old"])
    #expect(await store.load() == model.recentFolders)
  }

  @Test("A folder seeded by its spelling and created in again is one entry, not two")
  func seededEntryMergesWithTheCanonicalOne() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    ).path
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: folder) }
    // `/var/folders/…` is a link to `/private/var/folders/…`: two keys for one folder.
    let linked = folder.replacingOccurrences(of: "/private/var/", with: "/var/")
    let store = InMemoryRecentFolderStore()
    let model = AppModel(
      repository: HistoryRepository(values: [session(in: linked)]), recentFolderStore: store)
    await model.load()

    await model.complete(
      SessionCreation(session: session(in: linked), plan: plan(linked)), launching: false)

    #expect(model.recentFolders.entries.count == 1)
    #expect(model.recentFolders.entries.first?.key == CanonicalPath.of(folder))
  }

  @Test("A session created in a folder leaves its agent for the next one there (#534)")
  func creationRemembersTheAgent() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    ).path
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let store = InMemoryRecentFolderStore()
    let model = AppModel(
      repository: HistoryRepository(values: [session(in: folder)]), recentFolderStore: store)
    await model.load()
    #expect(model.rememberedAgent(forFolder: folder) == "stub")

    let codex = SessionDraft(
      name: "Session", initialPrompt: "", providerID: "codex", workingDirectoryPath: folder
    ).session(createdAt: Date(timeIntervalSince1970: 1_699_000_100))
    await model.complete(SessionCreation(session: codex, plan: plan(folder)), launching: false)

    #expect(model.rememberedAgent(forFolder: folder) == "codex")
    #expect(await store.load()?.entries.first?.providerID == "codex")
  }

  @Test("Two sessions started back to back leave the agent of the later one (#534)")
  func backToBackCreationsKeepTheLatestAgent() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    ).path
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let model = AppModel(
      repository: HistoryRepository(values: []), recentFolderStore: InMemoryRecentFolderStore())
    await model.load()
    func session(_ agent: String, at seconds: TimeInterval) -> WorkSession {
      SessionDraft(
        name: "Session", initialPrompt: "", providerID: agent, workingDirectoryPath: folder
      ).session(createdAt: Date(timeIntervalSince1970: seconds))
    }
    let earlier = session("codex", at: 1_699_000_000)
    let later = session("claude-code", at: 1_699_000_100)

    // The later one finishes launching first.
    await model.complete(SessionCreation(session: later, plan: plan(folder)), launching: false)
    await model.complete(SessionCreation(session: earlier, plan: plan(folder)), launching: false)

    #expect(model.rememberedAgent(forFolder: folder) == "claude-code")
  }

  @Test("A session switched to another agent leaves that agent to its folder (#534)")
  func switchedAgentIsRemembered() async throws {
    let store = InMemoryRecentFolderStore()
    var session = session(in: "/work/api")
    let model = AppModel(
      repository: HistoryRepository(values: [session, self.session(in: "/work/web")]),
      recentFolderStore: store)
    await model.load()

    session.agent = SessionAgentConfiguration(providerID: "codex")
    await model.rememberAgent(of: session)

    #expect(model.rememberedAgent(forFolder: "/work/api") == "codex")
    #expect(model.recentFolders.entries.map(\.path) == ["/work/web", "/work/api"])
    #expect(await store.load() == model.recentFolders)
  }

  @Test("A history written before agents were kept takes them from the sessions (#534)")
  func olderHistoryIsFilled() async {
    let store = InMemoryRecentFolderStore(RecentFolders([RecentFolder(lexicalPath: "/work/api")]))
    let model = AppModel(
      repository: HistoryRepository(values: [session(in: "/work/api")]), recentFolderStore: store)

    await model.load()

    #expect(model.recentFolders.entries.first?.providerID == "stub")
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

  @Test("A session created in a worktree leaves the history as it was (#529)")
  func creationInAWorktreeRecordsNothing() async {
    let store = InMemoryRecentFolderStore(RecentFolders(recent("/work/other")))
    let model = AppModel(repository: HistoryRepository(values: []), recentFolderStore: store)
    await model.load()
    // Read on disk at creation, wherever the worktree is…
    var linked = session(in: "/elsewhere/feat-1")
    linked.repositories[0].mainRepositoryPath = "/work/app"
    // …or named by its path.
    let named = session(in: "/work/app/.claude/worktrees/feat-2")

    for created in [linked, named] {
      let folder = created.repositories[0].path
      await model.complete(
        SessionCreation(session: created, plan: plan(folder)), launching: false)
    }

    #expect(model.offeredRecentFolders.map(\.path) == ["/work/other"])
    #expect(await store.load() == RecentFolders(recent("/work/other")))
  }

  @Test("Seeded from the sessions, the history leaves their worktrees out (#529)")
  func seedingLeavesWorktreesOut() async {
    let store = InMemoryRecentFolderStore()
    let model = AppModel(
      repository: HistoryRepository(values: [
        session(in: "/work/api/.claude/worktrees/feat-1", createdAt: 2),
        session(in: "/work/web", createdAt: 1),
      ]),
      recentFolderStore: store)

    await model.load()

    #expect(model.recentFolders.entries.map(\.path) == ["/work/web"])
    #expect(await store.load() == model.recentFolders)
  }

  @Test("A coordinator's child leaves the history as it was (#529)")
  func childCreationRecordsNothing() async {
    let store = InMemoryRecentFolderStore(RecentFolders(recent("/work/other")))
    let model = AppModel(repository: HistoryRepository(values: []), recentFolderStore: store)
    await model.load()
    var child = session(in: "/work/app")
    child.coordination = .child(of: SessionID())

    await model.complete(
      SessionCreation(session: child, plan: plan("/work/app")), launching: false)

    #expect(model.offeredRecentFolders.map(\.path) == ["/work/other"])
    #expect(await store.load() == RecentFolders(recent("/work/other")))
  }

  @Test("A history written with worktrees is written again without them at launch (#529)")
  func storedWorktreesAreDropped() async {
    var recorded = session(in: "/elsewhere/feat-3")
    recorded.repositories[0].mainRepositoryPath = "/work/api"
    let store = InMemoryRecentFolderStore(
      RecentFolders(
        recent(
          "/work/api/.claude/worktrees/feat-1", "/work/web", "/elsewhere/feat-3",
          "/work/api/.claude/worktrees/fix-2")))
    let model = AppModel(
      repository: HistoryRepository(values: [recorded]), recentFolderStore: store)

    await model.load()

    #expect(model.recentFolders.entries.map(\.path) == ["/work/web"])
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
    await waitUntil("the forgotten folder is left out of the store") {
      await store.load()?.entries.map(\.path) == ["/b"]
    }
  }

  private func recent(_ paths: String...) -> [RecentFolder] {
    paths.map { RecentFolder(lexicalPath: $0) }
  }
}

private struct UnreadableRepository: SessionRepository {
  struct Unreadable: Error {}

  func sessions() throws -> [WorkSession] { throw Unreadable() }
  func session(id: SessionID) throws -> WorkSession? { throw Unreadable() }
  func save(_: WorkSession) throws { throw Unreadable() }
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

/// Unreadable until told otherwise, like a store waiting on a recovery.
private actor RecoveringRepository: SessionRepository {
  struct Unreadable: Error {}

  private let values: [WorkSession]
  private var isReadable = false

  init(values: [WorkSession]) {
    self.values = values
  }

  func recover() { isReadable = true }

  func sessions() throws -> [WorkSession] {
    guard isReadable else { throw Unreadable() }
    return values
  }

  func session(id: SessionID) throws -> WorkSession? {
    try sessions().first { $0.id == id }
  }

  func save(_: WorkSession) {}
}
