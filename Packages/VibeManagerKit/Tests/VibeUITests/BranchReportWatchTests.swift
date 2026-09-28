import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Reading the branches of the session on screen", .timeLimit(.minutes(2)))
struct BranchReportWatchTests {
  private let api = WorkSession(
    name: "API",
    updatedAt: Date(timeIntervalSince1970: 2_000),
    repositories: [RepositoryContext(path: "/work/api")]
  )
  private let web = WorkSession(
    name: "Web",
    updatedAt: Date(timeIntervalSince1970: 1_000),
    repositories: [RepositoryContext(path: "/work/web")]
  )

  private func makeModel(
    reader: CountingReader, monitor: RepositoryStatusMonitor? = nil
  ) -> AppModel {
    AppModel(
      repository: WatchRepository(values: [api, web]),
      branchReader: ReadSessionBranchReport(reader: reader),
      repositoryStatus: monitor
    )
  }

  @Test("Only the selected session is read, and nothing is read again on a timer")
  func onlyTheSessionOnScreen() async throws {
    let reader = CountingReader()
    let model = makeModel(reader: reader)
    await model.load()
    model.select(api.id)
    await model.refreshBranchReport()
    try await Task.sleep(for: .milliseconds(150))

    #expect(await reader.reads(of: "/work/web") == 0)
    let settled = await reader.reads(of: "/work/api")
    #expect(model.branchReport(for: api.id)?.repositories.first?.checkedOutBranch == "main")
    try await Task.sleep(for: .milliseconds(300))
    #expect(await reader.reads(of: "/work/api") == settled)

    model.select(web.id)
    try await waitUntil("the other session's report is read") {
      await reader.reads(of: "/work/web") >= 1
    }
  }

  @Test("The repositories of the report are watched, and what the disk says lands in the model")
  func statusesReachTheModel() async throws {
    let reader = CountingReader()
    let events = HandFileChanges()
    let monitor = RepositoryStatusMonitor(reader: CleanStatusReader(), events: events)
    let model = makeModel(reader: reader, monitor: monitor)
    await model.load()
    model.select(api.id)

    try await waitUntil("the repository of the session on screen is read") {
      model.repositoryStatus(for: api.id, path: "/work/api")?.phase == .fresh
    }
    let before = await reader.reads(of: "/work/api")

    // A branch moved: the report is read again, without any timer.
    events.send(.changed(["/work/api/.git/refs/heads/main"]))
    try await waitUntil("a branch that moved on disk has the report read again") {
      await reader.reads(of: "/work/api") > before
    }

    // Another session on screen: the first one's repository is no longer watched.
    model.select(web.id)
    try await waitUntil("the session left is no longer watched") {
      model.repositoryStatus(for: api.id, path: "/work/api")?.phase == .unobserved
    }
    try await waitUntil("the repository of the new session on screen is read") {
      model.repositoryStatus(for: web.id, path: "/work/web")?.phase == .fresh
    }
    await model.stopWatchingRepositories()
  }

  @Test("Without Git there is no report at all")
  func noReportWithoutGit() async {
    let model = AppModel(repository: WatchRepository(values: [api]))
    await model.load()

    #expect(!model.reportsBranches)
    #expect(model.branchReport(for: api.id) == nil)
  }
}

@MainActor
@Suite("What a repository's state reads as")
struct RepositoryStatusPresentationTests {
  private let key = RepositoryStatusKey(sessionID: SessionID(), repositoryPath: "/work/api")

  private func state(
    _ entries: [(WorkingTreeEntry, Bool)],
    branch: BranchStatus = BranchStatus(branchName: "main"),
    operation: RepositoryOperation? = nil,
    phase: RepositoryStatusState.Phase = .fresh,
    sharedWith: [SessionID] = []
  ) -> RepositoryStatusState {
    var counts = WorkingTreeCounts()
    for (entry, _) in entries {
      if case .untracked = entry.kind { counts.untracked += 1 }
      if entry.isStaged { counts.staged += 1 }
      if entry.isUnstaged { counts.unstaged += 1 }
    }
    let status = WorkingTreeStatus(
      repositoryPath: "/work/api", branch: branch, operation: operation,
      entries: entries.map(\.0), counts: counts, observedAt: Date())
    return RepositoryStatusState(
      key: key, lastValid: status,
      entries: entries.map { AttributedEntry(entry: $0.0, touchedByAgent: $0.1) },
      phase: phase, sharedWith: sharedWith)
  }

  @Test("Counts in words, with what the transcript does not account for")
  func summary() {
    let staged = WorkingTreeEntry(path: "a", kind: .tracked(staged: .modified, unstaged: .modified))
    let untracked = WorkingTreeEntry(path: "b", kind: .untracked)
    let presentation = RepositoryStatusPresentation(
      state: state([(staged, true), (untracked, false)]))

    #expect(
      presentation.summary
        == "1 staged · 1 unstaged · 1 untracked — 1 not in this session's transcript")
    #expect(RepositoryStatusPresentation(state: state([])).summary == "No changes")
  }

  @Test("Distance, operation and sharing are said; a failure keeps the last state beside it")
  func details() {
    let other = SessionID()
    let failing = state(
      [], branch: BranchStatus(branchName: "main", upstream: "origin/main", ahead: 2, behind: 1),
      operation: .rebasing,
      phase: .failed(.unsafeRepository(path: "/work/api"), since: Date()), sharedWith: [other])
    let presentation = RepositoryStatusPresentation(
      state: failing, sessionNames: [other: "Audit deps"])

    #expect(
      presentation.details == [
        "2 ahead, 1 behind of upstream", "Rebase in progress", "Shared with Audit deps",
      ])
    #expect(presentation.summary == "No changes")
    #expect(presentation.isStale)
    #expect(presentation.command == "git config --global --add safe.directory /work/api")
  }
}

/// A state is waited for, not a deadline: the reading goes through several tasks (the report, the
/// monitor, its stream to the model), and a CI runner whose cooperative pool is saturated can leave
/// one of them unscheduled for seconds — three were given, and ran out. The bound is far beyond
/// what the slowest runner needs; it is only there so that a state never reached says which one,
/// rather than the suite's time limit saying nothing.
@MainActor
private func waitUntil(
  _ what: String, _ condition: @MainActor () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let start = clock.now
  while !(await condition()) {
    guard clock.now - start < .seconds(60) else {
      throw NeverReached(description: "Never reached: \(what).")
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

private struct NeverReached: Error, CustomStringConvertible {
  let description: String
}

private actor CountingReader: RepositoryActivityReading {
  private var counts: [String: Int] = [:]

  func reads(of path: String) -> Int { counts[path] ?? 0 }

  func head(atPath path: String) -> RepositoryHead? {
    counts[path, default: 0] += 1
    return RepositoryHead(checkedOutBranch: "main")
  }

  func repositoryRoot(containing path: String) -> String? { path }

  func reflog(atPath path: String, since date: Date) -> [ReflogEntry] { [] }

  func hasUncommittedChanges(atPath path: String, since date: Date) -> Bool { false }
}

private struct CleanStatusReader: RepositoryStatusReading {
  func status(atPath path: String, limit: Int) async -> Result<
    WorkingTreeStatus, RepositoryStatusIssue
  > {
    .success(
      WorkingTreeStatus(
        repositoryPath: path, branch: BranchStatus(branchName: "main"), entries: [],
        counts: WorkingTreeCounts(), observedAt: Date()))
  }

  func gitDirectories(atPath path: String) async -> Result<GitDirectories, RepositoryStatusIssue> {
    .success(GitDirectories(gitDirectory: path + "/.git", commonDirectory: path + "/.git"))
  }

  func untrackedFiles(in directory: String, atPath path: String, limit: Int) async -> Result<
    UntrackedListing, RepositoryStatusIssue
  > {
    .success(UntrackedListing(directory: directory, paths: [], totalCount: 0))
  }
}

private final class HandFileChanges: FileChangeObserving, @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [AsyncStream<FileChangeSignal>.Continuation] = []

  func signals(for paths: [String]) -> AsyncStream<FileChangeSignal> {
    let (stream, continuation) = AsyncStream.makeStream(of: FileChangeSignal.self)
    lock.withLock { continuations.append(continuation) }
    return stream
  }

  func send(_ signal: FileChangeSignal) {
    for continuation in lock.withLock({ continuations }) { continuation.yield(signal) }
  }
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
