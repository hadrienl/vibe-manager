import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private func folder(_ path: String, key: String? = nil) -> RecentFolder {
  RecentFolder(path: path, key: key ?? path)
}

private func session(folder path: String?, createdAt seconds: TimeInterval) -> WorkSession {
  WorkSession(
    name: "Session",
    initialPrompt: "",
    createdAt: Date(timeIntervalSince1970: seconds),
    updatedAt: Date(timeIntervalSince1970: seconds),
    repositories: path.map { [RepositoryContext(path: $0)] } ?? []
  )
}

@Suite("The recent folders")
struct RecentFoldersTests {
  @Test("The folder chosen last comes first")
  func mostRecentFirst() {
    let folders = RecentFolders()
      .recording(folder("/a"))
      .recording(folder("/b"))
      .recording(folder("/c"))

    #expect(folders.entries.map(\.path) == ["/c", "/b", "/a"])
  }

  @Test("Choosing a folder again moves it up without listing it twice")
  func choosingAgainMovesUp() {
    let folders = RecentFolders([folder("/c"), folder("/b"), folder("/a")])
      .recording(folder("/a"))

    #expect(folders.entries.map(\.path) == ["/a", "/c", "/b"])
  }

  @Test("Two spellings of one folder are one entry, under the spelling used last")
  func sameFolderDifferentSpelling() {
    let folders = RecentFolders([folder("/private/var/x", key: "/private/var/x"), folder("/b")])
      .recording(folder("/var/x", key: "/private/var/x"))

    #expect(folders.entries == [folder("/var/x", key: "/private/var/x"), folder("/b")])
  }

  @Test("Past the limit, the oldest folder goes")
  func boundedToTheLimit() {
    var folders = RecentFolders()
    for index in 0...RecentFolders.limit {
      folders = folders.recording(folder("/f\(index)"))
    }

    #expect(folders.entries.count == RecentFolders.limit)
    #expect(folders.entries.first?.path == "/f\(RecentFolders.limit)")
    #expect(!folders.entries.contains { $0.path == "/f0" })
  }

  @Test("A history built with duplicates keeps the first of each")
  func initializerDeduplicates() {
    let folders = RecentFolders([folder("/a"), folder("/b"), folder("/a")])

    #expect(folders.entries.map(\.path) == ["/a", "/b"])
  }

  @Test("Removing a folder leaves the others in their order")
  func removing() {
    let folders = RecentFolders([folder("/a"), folder("/b"), folder("/c")]).removing(key: "/b")

    #expect(folders.entries.map(\.path) == ["/a", "/c"])
  }

  @Test("The first history comes from the sessions, the newest first, each folder once")
  func seededFromSessions() {
    let sessions = [
      session(folder: "/old", createdAt: 1),
      session(folder: "/new", createdAt: 3),
      session(folder: nil, createdAt: 4),
      session(folder: "/new/", createdAt: 2),
      session(folder: "~/code", createdAt: 5),
    ]

    let folders = RecentFolders.seeded(from: sessions)

    #expect(folders.entries.map(\.path) == ["~/code", "/new", "/old"])
    #expect(folders.entries.first?.key == NSHomeDirectory() + "/code")
  }

  @Test("A session started in a worktree gives the history nothing (#529)")
  func seededWithoutWorktrees() {
    // A worktree as creation read it on disk, wherever it is.
    var recorded = session(folder: "/elsewhere/feat-1", createdAt: 3)
    recorded.repositories[0].mainRepositoryPath = "/code/app"
    let sessions = [
      recorded,
      // Created before the repository was kept with the session: named by its path.
      session(folder: "/code/app/.claude/worktrees/fix-2", createdAt: 2),
      session(folder: "/code/app", createdAt: 1),
    ]

    let folders = RecentFolders.seeded(from: sessions)

    #expect(folders.entries.map(\.path) == ["/code/app"])
  }

  @Test("A repository kept empty is no repository: the session's own folder is given")
  func emptyRepositoryFallsBackToTheFolder() {
    var recorded = session(folder: "/code/app", createdAt: 1)
    recorded.repositories[0].mainRepositoryPath = ""

    #expect(RecentFolders.folder(of: recorded) == "/code/app")
  }

  @Test("A coordinator's child gives the history nothing: its agent chose the folder (#529)")
  func childrenGiveNoFolder() {
    let coordinator = session(folder: "/code/app", createdAt: 1)
    var child = session(folder: "/scratch/task", createdAt: 2)
    child.coordination = .child(of: coordinator.id)

    #expect(RecentFolders.folder(of: child) == nil)
    #expect(RecentFolders.seeded(from: [coordinator, child]).entries.map(\.path) == ["/code/app"])
  }

  @Test("Worktrees already in the history are left out, their repository not put back (#529)")
  func droppingWorktrees() {
    let folders = RecentFolders([
      folder("/code/app/.claude/worktrees/feat-1"),
      folder("/code/web"),
      folder("/code/app/.worktrees/fix-2"),
      // Through a link: only the key, read on disk, names the worktree.
      folder("/Users/me/feat-3", key: "/code/api/.claude/worktrees/feat-3"),
      folder("/plain"),
    ]).droppingWorktrees(recordedIn: [])

    #expect(folders.entries.map(\.path) == ["/code/web", "/plain"])
  }

  @Test("A worktree placed anywhere is left out once a session recorded its repository (#529)")
  func droppingWorktreesNamedBySessions() {
    var recorded = session(folder: "~/Worktrees/app/feat-1", createdAt: 1)
    recorded.repositories[0].mainRepositoryPath = "/code/app"

    let folders = RecentFolders([folder("~/Worktrees/app/feat-1"), folder("/code/web")])
      .droppingWorktrees(recordedIn: [recorded])

    #expect(folders.entries.map(\.path) == ["/code/web"])
  }

  @Test("A history without worktrees is left as it is")
  func noWorktreeToDrop() {
    let folders = RecentFolders([folder("/a"), folder("/b")])

    #expect(folders.droppingWorktrees(recordedIn: [session(folder: "/a", createdAt: 1)]) == folders)
  }

  @Test("The first history stays within the limit")
  func seedingIsBounded() {
    let sessions = (0..<30).map { session(folder: "/f\($0)", createdAt: TimeInterval($0)) }

    let folders = RecentFolders.seeded(from: sessions)

    #expect(folders.entries.count == RecentFolders.limit)
    #expect(folders.entries.first?.path == "/f29")
  }

  @Test("A spelling is compared without the disk: tilde, dots and trailing slash")
  func lexicalKey() {
    #expect(RecentFolder.lexicalKey(of: "/a/b/../c/") == "/a/c")
    #expect(RecentFolder.lexicalKey(of: "~/x") == NSHomeDirectory() + "/x")
  }
}

@Suite("The names of recent folders")
struct RecentFolderNamesTests {
  @Test("A folder is named after itself")
  func ownName() {
    #expect(RecentFolderNames.displayNames(for: ["/code/api", "/code/web"]) == ["api", "web"])
  }

  @Test("Two folders of one name are told apart by the folder that differs")
  func namesakes() {
    let names = RecentFolderNames.displayNames(for: [
      "/work/client-a/api", "/work/client-b/api", "/work/web",
    ])

    #expect(names == ["api — client-a", "api — client-b", "web"])
  }

  @Test("When the parents match too, the name goes up until something differs")
  func namesakesWithSameParent() {
    let names = RecentFolderNames.displayNames(for: ["/one/src/api", "/two/src/api"])

    #expect(names == ["api — one", "api — two"])
  }
}

private func session(folder path: String, agent: String, createdAt seconds: TimeInterval)
  -> WorkSession
{
  var session = session(folder: path, createdAt: seconds)
  session.agent = SessionAgentConfiguration(providerID: agent)
  return session
}

@Suite("The agent of a recent folder (#534)")
struct RecentFolderAgentTests {
  @Test("A folder chosen again takes the agent of its new session")
  func recordingReplacesTheAgent() {
    let folders = RecentFolders([RecentFolder(path: "/a", key: "/a", providerID: "codex")])
      .recording(RecentFolder(path: "/a", key: "/a", providerID: "claude-code"))

    #expect(folders.agent(forFolder: "/a", sessions: []) == "claude-code")
  }

  @Test("The folder is found under another spelling, without the disk")
  func anotherSpelling() {
    let folders = RecentFolders([
      RecentFolder(path: "/work/api", key: "/private/work/api", providerID: "codex")
    ])

    #expect(folders.agent(forFolder: "/work/api/", sessions: []) == "codex")
    #expect(folders.agent(forFolder: "/private/work/api", sessions: []) == "codex")
    #expect(folders.agent(forFolder: "/work/web", sessions: []) == nil)
  }

  @Test("Without a recorded agent, the latest session of the folder gives it")
  func fallsBackOnTheSessions() {
    let folders = RecentFolders([folder("/a")])
    let sessions = [
      session(folder: "/a", agent: "codex", createdAt: 1),
      session(folder: "/a", agent: "claude-code", createdAt: 3),
      session(folder: "/b", agent: "gemini", createdAt: 5),
    ]

    #expect(folders.agent(forFolder: "/a", sessions: sessions) == "claude-code")
    // A folder that has left the history still has its sessions.
    #expect(folders.agent(forFolder: "/b", sessions: sessions) == "gemini")
    #expect(folders.agent(forFolder: "/c", sessions: sessions) == nil)
  }

  @Test("A coordinator's child does not speak for the folder its agent chose")
  func childrenGiveNoAgent() {
    var child = session(folder: "/a", agent: "codex", createdAt: 9)
    child.coordination = .child(of: SessionID())

    #expect(RecentFolders().agent(forFolder: "/a", sessions: [child]) == nil)
  }

  @Test("The first history takes each folder's latest agent")
  func seededWithAgents() {
    let folders = RecentFolders.seeded(from: [
      session(folder: "/a", agent: "codex", createdAt: 1),
      session(folder: "/a", agent: "claude-code", createdAt: 2),
    ])

    #expect(folders.entries.map(\.providerID) == ["claude-code"])
  }

  @Test("A switch of agent changes the folder's agent where it stands, and adds no folder")
  func recordingAnAgent() {
    let folders = RecentFolders([
      RecentFolder(path: "/a", key: "/a", providerID: "codex"),
      RecentFolder(path: "/b", key: "/b", providerID: "codex"),
    ])

    let switched = folders.recordingAgent("claude-code", forFolder: "/b/")

    #expect(switched.entries.map(\.path) == ["/a", "/b"])
    #expect(switched.entries.map(\.providerID) == ["codex", "claude-code"])
    #expect(folders.recordingAgent("claude-code", forFolder: "/c") == folders)
  }

  @Test("An older history takes each folder's latest agent, and keeps the ones it knows")
  func fillingAgents() {
    let folders = RecentFolders([
      folder("/a"), RecentFolder(path: "/b", key: "/b", providerID: "codex"), folder("/c"),
    ])
    let sessions = [
      session(folder: "/a", agent: "codex", createdAt: 1),
      session(folder: "/a", agent: "claude-code", createdAt: 2),
      session(folder: "/b", agent: "claude-code", createdAt: 3),
    ]

    #expect(
      folders.fillingAgents(from: sessions).entries.map(\.providerID)
        == ["claude-code", "codex", nil])
  }

  @Test("A history written before agents were kept reads as it was")
  func readsAnOlderHistory() throws {
    let json = #"[{"path":"/a","key":"/a"}]"#
    let folders = try JSONDecoder().decode(RecentFolders.self, from: Data(json.utf8))

    #expect(folders.entries == [folder("/a")])
    #expect(folders.entries.first?.providerID == nil)
  }

  @Test("The agent survives a round trip through the store's format")
  func roundTrip() throws {
    let folders = RecentFolders([RecentFolder(path: "/a", key: "/a", providerID: "codex")])
    let data = try JSONEncoder().encode(folders)

    #expect(try JSONDecoder().decode(RecentFolders.self, from: data) == folders)
  }
}
