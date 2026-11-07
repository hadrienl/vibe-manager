import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private func session(
  _ name: String,
  in paths: [String] = ["/work/api"],
  status: SessionStatus = .active,
  updatedAt: TimeInterval = 100,
  worktree: String? = nil
) -> WorkSession {
  WorkSession(
    name: name,
    status: status,
    createdAt: Date(timeIntervalSince1970: 10),
    updatedAt: Date(timeIntervalSince1970: updatedAt),
    closedAt: status == .active ? nil : Date(timeIntervalSince1970: 10),
    archivedAt: status == .archived ? Date(timeIntervalSince1970: updatedAt) : nil,
    repositories: paths.enumerated().map { index, path in
      RepositoryContext(
        path: path,
        git: index == 0 && worktree != nil
          ? GitSnapshot(repositoryRootPath: path, worktreePath: worktree) : nil)
    }
  )
}

private func lexical(_ session: WorkSession) -> SessionFolderKey? {
  SessionFolderKey.primaryPath(of: session).map(SessionFolderKey.lexical)
}

private func groups(
  _ sessions: [WorkSession],
  names: [SessionFolderKey: String] = [:]
) -> [SessionGroup] {
  SessionGrouping.groups(of: sessions, key: lexical, customNames: names)
}

@Suite("Grouping the sessions by working folder")
struct SessionGroupingTests {
  @Test("The sessions of one folder sit under one group")
  func oneFolderOneGroup() {
    let result = groups([session("A"), session("B"), session("C", in: ["/work/web"])])

    #expect(result.map(\.folderName) == ["api", "web"])
    #expect(result[0].sessions.map(\.name) == ["A", "B"])
  }

  @Test("Two folders of the same name in different trees are two groups, told apart")
  func homonymsAreDistinguished() {
    let result = groups([
      session("A", in: ["/clients/client-a/api"]),
      session("B", in: ["/clients/client-b/api"]),
      session("C", in: ["/work/web"]),
    ])

    #expect(result.count == 3)
    #expect(result.map(\.folderName) == ["api — client-a", "api — client-b", "web"])
  }

  @Test("Homonyms that share their parent are told apart by the first ancestor that differs")
  func homonymsWithTheSameParent() {
    let names = SessionGrouping.folderNames(of: [
      SessionFolderKey(path: "/one/src/api"), SessionFolderKey(path: "/two/src/api"),
    ])

    #expect(names[SessionFolderKey(path: "/one/src/api")] == "api — one")
    #expect(names[SessionFolderKey(path: "/two/src/api")] == "api — two")
  }

  @Test("Groups come in the order of their first session, and keep the order of the sort")
  func orderFollowsTheSort() {
    let sessions = [
      session("Newest web", in: ["/work/web"], updatedAt: 300),
      session("Api", updatedAt: 200),
      session("Older web", in: ["/work/web"], updatedAt: 100),
    ]

    for sort in SessionSort.allCases {
      let sorted = SessionFilter(sort: sort).apply(to: sessions)
      let result = groups(sorted)
      var seen: [SessionFolderKey] = []
      for folder in sorted.compactMap(lexical) where !seen.contains(folder) {
        seen.append(folder)
      }
      #expect(result.compactMap(\.id) == seen)
      for group in result {
        #expect(group.sessions == sorted.filter { lexical($0) == group.id })
      }
    }
  }

  @Test("A second repository and a worktree the agent made do not make a group of their own")
  func secondaryRepositoriesStayInTheMainGroup() {
    let result = groups([
      session("Multi", in: ["/work/api", "/work/shared"], worktree: "/work/api-worktrees/fix"),
      session("Plain"),
    ])

    #expect(result.count == 1)
    #expect(result[0].id == SessionFolderKey(path: "/work/api"))
    #expect(result[0].sessions.count == 2)
  }

  @Test("A renamed group keeps its folder, its path and its sessions")
  func renamingTouchesNothingElse() {
    let key = SessionFolderKey(path: "/work/api")
    let sessions = [session("A"), session("B")]
    let renamed = groups(sessions, names: [key: "Backend"])
    let plain = groups(sessions)

    #expect(renamed[0].title == "Backend")
    #expect(renamed[0].folderName == "api")
    #expect(renamed[0].id == plain[0].id)
    #expect(renamed[0].displayPath == plain[0].displayPath)
    #expect(renamed[0].sessions == plain[0].sessions)
  }

  @Test("A name made of spaces gives the group back its folder's")
  func blankNameIsNoName() {
    let renamed = groups([session("A")], names: [SessionFolderKey(path: "/work/api"): "   "])

    #expect(renamed[0].customName == nil)
    #expect(renamed[0].title == "api")
  }

  @Test("Sessions without a folder are filed last")
  func unfiledSessionsComeLast() {
    let result = groups([session("No folder", in: [], updatedAt: 300), session("Api")])

    #expect(result.map(\.id) == [SessionFolderKey(path: "/work/api"), nil])
  }

  @Test("A path is compared tidied: spaces kept, tilde expanded, no trailing slash")
  func lexicalKeys() {
    #expect(
      SessionFolderKey.lexical("/work/My Project/") == SessionFolderKey(path: "/work/My Project"))
    #expect(SessionFolderKey.lexical("/work/./api/../api") == SessionFolderKey(path: "/work/api"))
    #expect(
      SessionFolderKey.lexical("~/Code").path
        == (NSHomeDirectory() as NSString).appendingPathComponent("Code"))
    let result = groups([session("A", in: ["/work/api/"]), session("B")])
    #expect(result.count == 1)
  }
}

@Suite("Filing a folder where the disk says it is")
struct SessionFolderKeyDiskTests {
  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeGroups-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test("A folder and a link to it are one group")
  func symbolicLinksAreFollowed() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("My Project", isDirectory: true)
    let link = root.appendingPathComponent("Shortcut", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let resolution = await SessionFolderResolution.resolve([real.path, link.path])

    #expect(resolution.keys[real.path] == resolution.keys[link.path])
    #expect(resolution.missing.isEmpty)
  }

  @Test("/var and /private/var are the same folder")
  func privateVarIsVar() {
    #expect(
      SessionFolderKey.canonical("/var/tmp") == SessionFolderKey.canonical("/private/var/tmp"))
  }

  @Test("A deleted folder keeps its key, and is said to be missing")
  func deletedFolderKeepsItsKey() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("api with spaces", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let before = await SessionFolderResolution.resolve([folder.path])

    try FileManager.default.removeItem(at: folder)
    let after = await SessionFolderResolution.resolve([folder.path])

    #expect(before.keys[folder.path] == after.keys[folder.path])
    #expect(after.missing == [try #require(after.keys[folder.path])])
  }

  @Test("A moved folder stays under its old path, marked missing")
  func movedFolderStaysWhereItWas() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("api", isDirectory: true)
    let moved = root.appendingPathComponent("api-renamed", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: folder, to: moved)

    let resolution = await SessionFolderResolution.resolve([folder.path])
    let key = try #require(resolution.keys[folder.path])

    #expect(key.path.hasSuffix("/api"))
    #expect(resolution.missing.contains(key))
    let grouped = SessionGrouping.groups(
      of: [session("A", in: [folder.path])], key: { _ in key }, missingFolders: resolution.missing)
    #expect(grouped[0].isMissing)
    #expect(grouped[0].folderName == "api")
  }

  /// A repository at `root/name` and a linked worktree of it, its `.git` a file as Git writes it.
  private func worktree(
    _ worktree: URL, of repository: URL, relative: Bool = false
  ) throws {
    let gitDirectory = repository.appendingPathComponent(
      ".git/worktrees/\(worktree.lastPathComponent)")
    try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    let target =
      relative
      ? String(repeating: "../", count: worktree.pathComponents.count - 1)
        + gitDirectory.path.dropFirst()
      : gitDirectory.path
    try "gitdir: \(target)\n".write(
      to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
  }

  @Test("A worktree, wherever it is, is filed under its repository (#525)")
  func worktreeIsFiledUnderItsRepository() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appendingPathComponent("mairie", isDirectory: true)
    let inside = repository.appendingPathComponent(".claude/worktrees/TICKET-185")
    let outside = root.appendingPathComponent("mairie-worktrees/15-release")
    let relative = root.appendingPathComponent("elsewhere/TICKET-190")
    try worktree(inside, of: repository)
    try worktree(outside, of: repository)
    try worktree(relative, of: repository, relative: true)

    let resolution = await SessionFolderResolution.resolve([
      repository.path, inside.path, outside.path, relative.path,
    ])

    let key = try #require(resolution.keys[repository.path])
    #expect(resolution.keys[inside.path] == key)
    #expect(resolution.keys[outside.path] == key)
    #expect(resolution.keys[relative.path] == key)
    #expect(resolution.missing.isEmpty)
  }

  @Test("A worktree removed since is filed under the repository its path names (#525)")
  func removedWorktreeIsFiledUnderItsRepository() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appendingPathComponent("mairie", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    let claude = repository.appendingPathComponent(".claude/worktrees/TICKET-186").path
    let plain = repository.appendingPathComponent(".worktrees/fix-54").path
    let elsewhere = root.appendingPathComponent("mairie-worktrees/15-release").path

    let resolution = await SessionFolderResolution.resolve([
      repository.path, claude, plain, elsewhere,
    ])

    let key = try #require(resolution.keys[repository.path])
    #expect(resolution.keys[claude] == key)
    #expect(resolution.keys[plain] == key)
    #expect(!resolution.missing.contains(key))
    // Nothing in its path names its repository: it stays under its own, missing.
    let lost = try #require(resolution.keys[elsewhere])
    #expect(lost.path.hasSuffix("/15-release"))
    #expect(resolution.missing.contains(lost))
  }

  @Test("A clone and a submodule are their own folders")
  func cloneAndSubmoduleStayThemselves() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let clone = root.appendingPathComponent("api", isDirectory: true)
    try FileManager.default.createDirectory(
      at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let submodule = clone.appendingPathComponent("vendor/lib", isDirectory: true)
    try FileManager.default.createDirectory(at: submodule, withIntermediateDirectories: true)
    try "gitdir: ../../.git/modules/lib\n".write(
      to: submodule.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

    let resolution = await SessionFolderResolution.resolve([clone.path, submodule.path])

    #expect(resolution.keys[clone.path] == .canonical(clone.path))
    #expect(resolution.keys[submodule.path] == .canonical(submodule.path))
  }
}

@Suite("The repository of a worktree (#525)")
struct WorktreeRepositoryTests {
  @Test("Its path names it under .claude/worktrees and .worktrees, never under Codex's home")
  func inPath() {
    #expect(WorktreeRepository.inPath(of: "/w/mairie/.claude/worktrees/TICKET-185") == "/w/mairie")
    #expect(WorktreeRepository.inPath(of: "/w/mairie/.worktrees/fix-54/backoffice") == "/w/mairie")
    // A worktree made from another hangs from the clone.
    #expect(
      WorktreeRepository.inPath(of: "/w/api/.claude/worktrees/a/.claude/worktrees/b") == "/w/api")
    #expect(WorktreeRepository.inPath(of: "/Users/me/.codex/worktrees/1a2b/api") == nil)
    #expect(WorktreeRepository.inPath(of: "/w/mairie/.claude/worktrees/") == nil)
    #expect(WorktreeRepository.inPath(of: "/w/mairie") == nil)
  }

  @Test("A session started in a worktree is filed under the repository it recorded")
  func recordedRepositoryWins() {
    let child = WorkSession(
      name: "TICKET-185",
      createdAt: Date(timeIntervalSince1970: 10),
      updatedAt: Date(timeIntervalSince1970: 10),
      repositories: [
        RepositoryContext(
          path: "/w/elsewhere/TICKET-185", mainRepositoryPath: "/w/mairie")
      ])

    #expect(SessionFolderKey.primaryPath(of: child) == "/w/mairie")
    #expect(child.repositories[0].path == "/w/elsewhere/TICKET-185")
  }

  @Test("Before the disk answers, a worktree's path already files it under its repository")
  func provisionalKey() {
    #expect(
      SessionFolderKey.provisional("/w/mairie/.claude/worktrees/TICKET-185")
        == .lexical("/w/mairie"))
    #expect(SessionFolderKey.provisional("~/w/api/") == .lexical("~/w/api"))
  }
}

@Suite("Keeping the grouped sidebar in the layout")
struct WorkspaceLayoutGroupingTests {
  @Test("The mode and the folds come back as they were left")
  func roundTrip() throws {
    let layout = WorkspaceLayout(
      sidebarMode: .byFolder,
      collapsedFolders: [SessionFolderKey(path: "/work/api"), SessionFolderKey(path: "")])

    let decoded = try JSONDecoder().decode(
      WorkspaceLayout.self, from: try JSONEncoder().encode(layout))

    #expect(decoded == layout)
  }

  @Test("A layout written before groups reads as a flat list, nothing folded")
  func olderLayout() throws {
    let data = Data(#"{"sidebarWidth": 300, "isInspectorVisible": false}"#.utf8)

    let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: data)

    #expect(decoded.sidebarMode == .flat)
    #expect(decoded.collapsedFolders.isEmpty)
    #expect(decoded.sidebarWidth == 300)
    #expect(!decoded.isInspectorVisible)
  }

  @Test("A mode written by a later build costs the grouping, not the rest of the layout")
  func unknownModeFallsBack() throws {
    let data = Data(
      #"{"sidebarWidth": 300, "sidebarMode": "byPriority", "collapsedFolders": 12}"#.utf8)

    let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: data)

    #expect(decoded.sidebarMode == .flat)
    #expect(decoded.collapsedFolders.isEmpty)
    #expect(decoded.sidebarWidth == 300)
  }
}
