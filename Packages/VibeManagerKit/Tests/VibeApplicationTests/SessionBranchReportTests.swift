import Foundation
import Testing
import VibeApplication
import VibeDomain

@Suite("Telling a session where it worked, and on which branch")
struct SessionBranchReportTests {
  private let start = Date(timeIntervalSince1970: 1_000)

  private func session(_ repositories: [RepositoryContext]) -> WorkSession {
    WorkSession(
      name: "Session", createdAt: start, updatedAt: start, closedAt: start, startedAt: start,
      repositories: repositories)
  }

  private func read(
    _ session: WorkSession,
    activity: TranscriptActivity?,
    reader: FakeRepositories = FakeRepositories()
  ) async -> SessionBranchReport {
    await ReadSessionBranchReport(
      reader: reader, transcripts: FixedTranscript(activity: activity))(for: session)
  }

  @Test("The repositories come from the transcript, filed under the folder they are in")
  func repositoriesFromTheTranscript() async {
    let folder = RepositoryContext(rootPath: "/projects", mode: .inPlace)
    let report = await read(
      session([folder]),
      activity: TranscriptActivity(
        editedPaths: ["/projects/api/Sources/a.swift"],
        workingDirectories: ["/projects", "/projects/web"]))

    #expect(report.found(in: folder.id).map(\.name) == ["api"])
    #expect(report.visitedOnly == ["web"])
    #expect(report.report(for: folder.id, path: folder.effectivePath) == nil)
  }

  @Test("Only the branch checked out is reported: the others may be anyone's")
  func onlyTheCheckedOutBranch() async throws {
    let reader = FakeRepositories(reflog: [
      ReflogEntry(branch: "main", date: start.addingTimeInterval(5), subject: "commit: Mine"),
      ReflogEntry(branch: "other", date: start.addingTimeInterval(6), subject: "commit: Theirs"),
    ])
    let report = await read(
      session([]), activity: TranscriptActivity(editedPaths: ["/projects/api/a"]),
      reader: reader)

    let repository = try #require(report.repositories.first)
    #expect(repository.change == BranchChange(name: "main", kind: .advanced, commitCount: 1))
    #expect(repository.changes.count == 1)
  }

  @Test("A repository outside every attached folder is reported on its own")
  func elsewhere() async {
    let report = await read(
      session([RepositoryContext(rootPath: "/projects/api", mode: .inPlace)]),
      activity: TranscriptActivity(editedPaths: ["/elsewhere/lib/x"]))

    #expect(report.elsewhere.map(\.name) == ["/elsewhere/lib"])
    #expect(report.repositories.first?.involvement == .attached)
  }

  @Test("A worktree an agent made for itself is named after its clone")
  func agentWorktreeName() async {
    let folder = RepositoryContext(rootPath: "/projects", mode: .plainFolder)
    let report = await read(
      session([folder]),
      activity: TranscriptActivity(editedPaths: ["/projects/Mobile/.claude/worktrees/230/x"]))

    #expect(report.found(in: folder.id).map(\.name) == ["Mobile · worktree 230"])
  }

  @Test("Without a transcript, only the attached repositories are known, and that is said")
  func withoutTranscript() async {
    let attached = RepositoryContext(rootPath: "/projects/api", mode: .inPlace)
    let report = await read(session([attached]), activity: nil)

    #expect(!report.hasTranscript)
    #expect(report.report(for: attached.id, path: attached.effectivePath)?.name == "api")
  }

  @Test("A reflog reads as created, moved forward or rewritten")
  func reflogClassification() {
    func change(_ subjects: [String]) -> BranchChange? {
      BranchChange.fromReflogForTests(
        subjects.enumerated().map {
          ReflogEntry(
            branch: "b", date: Date(timeIntervalSince1970: Double($0.offset)), subject: $0.element)
        })
    }
    #expect(change(["branch: Created from HEAD", "commit: a", "commit: b"])?.kind == .created)
    #expect(change(["branch: Created from HEAD", "commit: a"])?.commitCount == 1)
    #expect(change(["commit: a", "pull: Fast-forward"])?.kind == .advanced)
    #expect(change(["rebase (finish): refs/heads/b onto 1a2b"])?.kind == .rewritten)
    #expect(change([]) == nil)
  }
}

/// Every path under a folder of `/projects`, or of any other top folder, belongs to the
/// repository named by its first two components.
private struct FakeRepositories: RepositoryActivityReading {
  var reflog: [ReflogEntry] = []

  func references(atPath path: String) async -> GitReferenceSnapshot? {
    GitReferenceSnapshot(checkedOutBranch: "main", headRevision: "a", branches: ["main": "a"])
  }

  func repositoryRoot(containing path: String) async -> String? {
    let components = path.split(separator: "/")
    guard components.count >= 2, path != "/projects" else { return nil }
    if let marker = components.firstIndex(of: "worktrees"), marker + 1 < components.count {
      return "/" + components[...(marker + 1)].joined(separator: "/")
    }
    return "/" + components.prefix(2).joined(separator: "/")
  }

  func reflog(atPath path: String, since date: Date) async -> [ReflogEntry] { reflog }

  func hasUncommittedChanges(atPath path: String, since date: Date) async -> Bool { false }
}

private struct FixedTranscript: SessionTranscriptReading {
  let activity: TranscriptActivity?

  func activity(for session: WorkSession) async -> TranscriptActivity? { activity }
}
