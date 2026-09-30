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
    let folder = RepositoryContext(path: "/projects")
    let report = await read(
      session([folder]),
      activity: TranscriptActivity(
        editedPaths: ["/projects/api/Sources/a.swift"],
        workingDirectories: ["/projects", "/projects/web"]))

    #expect(report.repositories.map(\.name) == ["api"])
    #expect(report.repositories.first?.involvement == .edited)
    #expect(report.visitedOnly == ["web"])
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
  }

  @Test("A repository outside the session's folder is named by its path, after the folder")
  func elsewhere() async {
    let report = await read(
      session([RepositoryContext(path: "/projects/api")]),
      activity: TranscriptActivity(editedPaths: ["/elsewhere/lib/x"]))

    #expect(report.repositories.map(\.name) == ["api", "/elsewhere/lib"])
    #expect(report.repositories.first?.involvement == .attached)
  }

  @Test("A worktree an agent made for itself is named after its clone")
  func agentWorktreeName() async {
    let folder = RepositoryContext(path: "/projects")
    let report = await read(
      session([folder]),
      activity: TranscriptActivity(editedPaths: ["/projects/Mobile/.claude/worktrees/230/x"]))

    #expect(report.repositories.map(\.name) == ["Mobile · worktree 230"])
  }

  @Test("Without a transcript, only the attached repositories are known, and that is said")
  func withoutTranscript() async {
    let attached = RepositoryContext(path: "/projects/api")
    let report = await read(session([attached]), activity: nil)

    #expect(!report.hasTranscript)
    #expect(report.repositories.map(\.name) == ["api"])
  }

  @Test("A reflog reads as created, moved forward or rewritten")
  func reflogClassification() {
    func change(_ subjects: [String]) -> BranchChange? {
      BranchChange.fromReflog(
        branch: "b",
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

@Suite("Running Git for the report only when a repository moved")
struct SessionBranchReportCacheTests {
  private let start = Date(timeIntervalSince1970: 1_000)

  private func session(attached: String = "/projects/api") -> WorkSession {
    WorkSession(
      name: "Session", createdAt: start, updatedAt: start, startedAt: start,
      repositories: [RepositoryContext(path: attached)])
  }

  private func status(dirty: Bool, observedAt: Date) throws -> WorkingTreeStatus {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeReport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Written now, so after `start`: listed, it counts as the agent's.
    try Data("x".utf8).write(to: folder.appendingPathComponent("a.swift"))
    return WorkingTreeStatus(
      repositoryPath: folder.path, branch: BranchStatus(branchName: "main"),
      entries: dirty ? [WorkingTreeEntry(path: "a.swift", kind: .untracked)] : [],
      counts: WorkingTreeCounts(untracked: dirty ? 1 : 0), observedAt: observedAt)
  }

  @Test("The same fingerprint twice: the branches are read once")
  func sameFingerprint() async {
    let reader = FingerprintedRepositories()
    let read = ReadSessionBranchReport(reader: reader)

    let first = await read(for: session())
    let second = await read(for: session())

    #expect(await reader.calls("head") == 1)
    #expect(await reader.calls("reflog") == 1)
    #expect(first.repositories == second.repositories)
  }

  @Test("A reference that moved has the branches read again")
  func movedReference() async {
    let reader = FingerprintedRepositories()
    let read = ReadSessionBranchReport(reader: reader)

    _ = await read(for: session())
    await reader.moveReferences()
    _ = await read(for: session())

    #expect(await reader.calls("head") == 2)
    #expect(await reader.calls("reflog") == 2)
  }

  @Test("Without a fingerprint, every reading runs Git, as before")
  func withoutFingerprint() async {
    let reader = FingerprintedRepositories(fingerprints: false)
    let read = ReadSessionBranchReport(reader: reader)

    _ = await read(for: session())
    _ = await read(for: session())

    #expect(await reader.calls("head") == 2)
  }

  @Test("A forced reading trusts nothing already read")
  func forced() async {
    let reader = FingerprintedRepositories()
    let read = ReadSessionBranchReport(reader: reader)

    _ = await read(for: session())
    _ = await read(for: session(), forced: true)

    #expect(await reader.calls("head") == 2)
    #expect(await reader.calls("status") == 2)
  }

  @Test("A repository the monitor watches is told dirty by its status, without a second one")
  func watchedRepository() async throws {
    let reader = FingerprintedRepositories()
    let known = try status(dirty: true, observedAt: start.addingTimeInterval(10))
    let read = ReadSessionBranchReport(
      reader: reader, knownStatus: { _, _ in known })

    let report = await read(for: session())
    _ = await read(for: session())

    #expect(report.repositories.first?.isDirty == true)
    #expect(await reader.calls("status") == 0)
  }

  @Test("A repository the monitor does not watch runs its own status at most every 30 s")
  func unwatchedRepository() async {
    let reader = FingerprintedRepositories()
    let clock = MovableClock(start)
    let read = ReadSessionBranchReport(reader: reader, clock: clock)

    _ = await read(for: session())
    clock.advance(by: 29)
    _ = await read(for: session())
    #expect(await reader.calls("status") == 1)

    clock.advance(by: 2)
    _ = await read(for: session())
    #expect(await reader.calls("status") == 2)
  }

  @Test("A status cut short without an answer is not taken for clean")
  func truncatedStatus() async throws {
    let reader = FingerprintedRepositories(dirty: true)
    let clean = try status(dirty: false, observedAt: start)
    let truncated = WorkingTreeStatus(
      repositoryPath: clean.repositoryPath, branch: clean.branch, entries: [],
      counts: WorkingTreeCounts(untracked: 5000), isTruncated: true, observedAt: start)
    let read = ReadSessionBranchReport(reader: reader, knownStatus: { _, _ in truncated })

    let report = await read(for: session())

    #expect(report.repositories.first?.isDirty == true)
    #expect(await reader.calls("status") == 1)
  }

  @Test("A repository only visited, and unchanged, costs no Git at the second reading")
  func visitedOnly() async {
    let reader = FingerprintedRepositories()
    let read = ReadSessionBranchReport(
      reader: reader,
      transcripts: FixedTranscript(
        activity: TranscriptActivity(workingDirectories: ["/projects/web"])))
    let bare = WorkSession(name: "Session", createdAt: start, updatedAt: start, startedAt: start)

    let first = await read(for: bare)
    let before = await reader.total()
    let second = await read(for: bare)

    #expect(first.visitedOnly == ["/projects/web"])
    #expect(second.visitedOnly == first.visitedOnly)
    #expect(await reader.total() == before)
  }

  @Test("Two readings that differ only by their date say the same thing")
  func sameContent() {
    let id = SessionID()
    let first = SessionBranchReport(sessionID: id, repositories: [], readAt: start)
    let later = SessionBranchReport(
      sessionID: id, repositories: [], readAt: start.addingTimeInterval(60))

    #expect(first.hasSameContent(as: later))
    #expect(first != later)
    #expect(first.checked(at: later.readAt) == later)
  }
}

/// Counts what the report asks Git, and says the references never move unless told.
private actor FingerprintedRepositories: RepositoryActivityReading {
  private let fingerprints: Bool
  private let dirty: Bool
  private var counts: [String: Int] = [:]
  private var generation: UInt64 = 1

  init(fingerprints: Bool = true, dirty: Bool = false) {
    self.fingerprints = fingerprints
    self.dirty = dirty
  }

  func calls(_ name: String) -> Int { counts[name] ?? 0 }
  func total() -> Int { counts.values.reduce(0, +) }
  func moveReferences() { generation += 1 }

  func head(atPath path: String) -> RepositoryHead? {
    counts["head", default: 0] += 1
    return RepositoryHead(checkedOutBranch: "main")
  }

  func repositoryRoot(containing path: String) -> String? {
    let components = path.split(separator: "/")
    guard components.count >= 2 else { return nil }
    return "/" + components.prefix(2).joined(separator: "/")
  }

  func reflog(atPath path: String, since date: Date) -> [ReflogEntry] {
    counts["reflog", default: 0] += 1
    return []
  }

  func hasUncommittedChanges(atPath path: String, since date: Date) -> Bool {
    counts["status", default: 0] += 1
    return dirty
  }

  func referenceFingerprint(atPath path: String) -> ReferenceFingerprint? {
    guard fingerprints else { return nil }
    return ReferenceFingerprint(stamps: [
      "HEAD": ReferenceFingerprint.Stamp(inode: 1, size: 21, modified: Int64(generation))
    ])
  }
}

private final class MovableClock: SessionClock, @unchecked Sendable {
  private let lock = NSLock()
  private var moment: Date

  init(_ moment: Date) {
    self.moment = moment
  }

  func now() -> Date { lock.withLock { moment } }

  func advance(by seconds: TimeInterval) {
    lock.withLock { moment = moment.addingTimeInterval(seconds) }
  }
}

/// Every path under a folder of `/projects`, or of any other top folder, belongs to the
/// repository named by its first two components.
private struct FakeRepositories: RepositoryActivityReading {
  var reflog: [ReflogEntry] = []

  func head(atPath path: String) async -> RepositoryHead? {
    RepositoryHead(checkedOutBranch: "main")
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
