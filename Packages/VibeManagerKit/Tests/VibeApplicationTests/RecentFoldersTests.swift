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
