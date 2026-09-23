import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Reading the branches of the session on screen")
struct BranchReportWatchTests {
  private let api = WorkSession(
    name: "API",
    updatedAt: Date(timeIntervalSince1970: 2_000),
    repositories: [RepositoryContext(rootPath: "/work/api")]
  )
  private let web = WorkSession(
    name: "Web",
    updatedAt: Date(timeIntervalSince1970: 1_000),
    repositories: [RepositoryContext(rootPath: "/work/web")]
  )

  private func makeModel(reader: CountingReader) -> AppModel {
    AppModel(
      repository: WatchRepository(values: [api, web]),
      workspace: SessionWorkspaceServices(
        inspector: NoInspector(),
        writer: NoWriter(),
        root: FixedWorktreeRoot(path: "/roots"),
        activity: reader
      ),
      branchReportInterval: .milliseconds(10)
    )
  }

  @Test("Only the selected session is read, and a closed one only once")
  func onlyTheSessionOnScreen() async throws {
    let reader = CountingReader()
    let model = makeModel(reader: reader)
    await model.load()
    model.select(api.id)
    await model.refreshBranchReport()
    try await Task.sleep(for: .milliseconds(80))

    #expect(await reader.reads(of: "/work/web") == 0)
    // No agent runs behind it: nothing moves, so nothing is read again on the timer.
    #expect(await reader.reads(of: "/work/api") <= 3)
    #expect(model.branchReport(for: api.id)?.repositories.first?.checkedOutBranch == "main")

    model.select(web.id)
    try await Task.sleep(for: .milliseconds(30))
    #expect(await reader.reads(of: "/work/web") >= 1)
  }

  @Test("Without Git there is no report at all")
  func noReportWithoutGit() async {
    let model = AppModel(repository: WatchRepository(values: [api]))
    await model.load()

    #expect(!model.reportsBranches)
    #expect(model.branchReport(for: api.id) == nil)
  }
}

private actor CountingReader: RepositoryActivityReading {
  private var counts: [String: Int] = [:]

  func reads(of path: String) -> Int { counts[path] ?? 0 }

  func references(atPath path: String) -> GitReferenceSnapshot? {
    counts[path, default: 0] += 1
    return GitReferenceSnapshot(
      checkedOutBranch: "main", headRevision: "abc", branches: ["main": "abc"])
  }

  func repositoryRoot(containing path: String) -> String? { path }

  func reflog(atPath path: String, since date: Date) -> [ReflogEntry] { [] }

  func hasUncommittedChanges(atPath path: String, since date: Date) -> Bool { false }
}

private struct NoInspector: RepositoryInspecting {
  func inspect(path: String) async -> RepositoryInspection { .plainFolder }
}

private struct NoWriter: WorktreeCreating {
  func createSessionFolder(atPath path: String) async throws {}
  func createWorktree(_ request: WorktreeCreationRequest) async throws {}
  func createBranchInPlace(repositoryPath: String, commonDirectory: String, branch: String)
    async throws
  {}
}

private actor WatchRepository: SessionRepository {
  private let values: [WorkSession]

  init(values: [WorkSession]) {
    self.values = values
  }

  func sessions() -> [WorkSession] { values }
  func session(id: SessionID) -> WorkSession? { values.first { $0.id == id } }
  func save(_: WorkSession) {}
}
