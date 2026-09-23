import Foundation
import VibeApplication
import VibeDomain

/// A repository reader that answers from a table, counts what it is asked, and can hold its
/// answers back to show what happens while a reading is under way.
actor ScriptedStatusReader: RepositoryStatusReading {
  private var answers: [String: Result<WorkingTreeStatus, RepositoryStatusIssue>] = [:]
  private var directories: [String: GitDirectories] = [:]
  private var reads: [String: Int] = [:]
  private var running = 0
  private(set) var mostAtOnce = 0
  private var isHeld = false
  private var held: [CheckedContinuation<Void, Never>] = []

  func answer(_ path: String, with result: Result<WorkingTreeStatus, RepositoryStatusIssue>) {
    answers[path] = result
  }

  func answer(_ path: String, entries: [WorkingTreeEntry], lock: IndexLock? = nil) {
    answers[path] = .success(.sample(path, entries: entries, lock: lock))
  }

  func place(_ path: String, gitDirectory: String, commonDirectory: String? = nil) {
    directories[path] = GitDirectories(
      gitDirectory: gitDirectory, commonDirectory: commonDirectory ?? gitDirectory)
  }

  func readCount(_ path: String) -> Int { reads[path] ?? 0 }

  func hold() { isHeld = true }

  func release() {
    isHeld = false
    let waiting = held
    held = []
    for continuation in waiting { continuation.resume() }
  }

  func status(atPath path: String, limit: Int) async -> Result<
    WorkingTreeStatus, RepositoryStatusIssue
  > {
    reads[path, default: 0] += 1
    running += 1
    mostAtOnce = max(mostAtOnce, running)
    if isHeld {
      await withCheckedContinuation { held.append($0) }
    }
    running -= 1
    return answers[path] ?? .success(.sample(path, entries: []))
  }

  private(set) var listings = 0

  func untrackedFiles(in directory: String, atPath path: String, limit: Int) async -> Result<
    UntrackedListing, RepositoryStatusIssue
  > {
    listings += 1
    running += 1
    mostAtOnce = max(mostAtOnce, running)
    if isHeld {
      await withCheckedContinuation { held.append($0) }
    }
    running -= 1
    let paths = (0..<3).map { "\(directory)file\($0).txt" }
    return .success(
      UntrackedListing(directory: directory, paths: Array(paths.prefix(limit)), totalCount: 3))
  }

  func gitDirectories(atPath path: String) async -> Result<GitDirectories, RepositoryStatusIssue> {
    if let known = directories[path] { return .success(known) }
    return .success(GitDirectories(gitDirectory: path + "/.git", commonDirectory: path + "/.git"))
  }
}

/// File system events sent by hand, to every stream open at the time.
final class ManualFileChanges: FileChangeObserving, @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<FileChangeSignal>.Continuation] = [:]
  private var watched: [[String]] = []

  var watchedPaths: [String] { lock.withLock { watched.last ?? [] } }
  var openStreams: Int { lock.withLock { continuations.count } }

  func signals(for paths: [String]) -> AsyncStream<FileChangeSignal> {
    let (stream, continuation) = AsyncStream.makeStream(of: FileChangeSignal.self)
    let id = UUID()
    lock.withLock {
      continuations[id] = continuation
      watched.append(paths)
    }
    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      self.lock.withLock { self.continuations[id] = nil }
    }
    return stream
  }

  func send(_ signal: FileChangeSignal) {
    let all = lock.withLock { Array(continuations.values) }
    for continuation in all { continuation.yield(signal) }
  }
}

/// A transcript whose edited paths the test sets.
actor TableTranscriptSource: SessionTranscriptSource {
  private var edited: Set<String>
  private let directories: [String]

  init(edited: Set<String> = [], directories: [String] = []) {
    self.edited = edited
    self.directories = directories
  }

  func setEdited(_ paths: Set<String>) { edited = paths }

  func activity(for session: WorkSession) async -> TranscriptActivity? {
    TranscriptActivity(editedPaths: edited)
  }

  func transcriptDirectories(for session: WorkSession) async -> [String] { directories }
}

/// Everything a monitor publishes, gathered as it comes.
actor StatusUpdateRecorder {
  private(set) var updates: [RepositoryStatusUpdate] = []

  func record(_ update: RepositoryStatusUpdate) { updates.append(update) }

  var states: [RepositoryStatusState] {
    updates.flatMap { update -> [RepositoryStatusState] in
      if case .states(let states) = update { return states }
      return []
    }
  }

  var outdatedReports: Int {
    updates.filter {
      if case .branchReportOutdated = $0 { return true }
      return false
    }.count
  }

  func latest(_ path: String) -> RepositoryStatusState? {
    states.last { $0.key.repositoryPath == path }
  }

  func publications(of path: String) -> Int {
    states.filter { $0.key.repositoryPath == path }.count
  }

  static func listening(to monitor: RepositoryStatusMonitor) -> StatusUpdateRecorder {
    let recorder = StatusUpdateRecorder()
    Task {
      for await update in monitor.updates {
        await recorder.record(update)
      }
    }
    return recorder
  }
}

/// A clock that says one moment once, then another from then on.
final class SteppingClock: SessionClock, @unchecked Sendable {
  private let lock = NSLock()
  private var moments: [Date]

  init(_ first: Date, then later: Date) {
    moments = [first, later]
  }

  func now() -> Date {
    lock.withLock { moments.count > 1 ? moments.removeFirst() : moments[0] }
  }
}

/// Waits for a condition that an actor elsewhere will make true, and fails after `timeout`.
///
/// The timeout is only ever reached by a test that fails: a loaded CI runner may take seconds to
/// schedule what takes milliseconds here.
func eventually(
  timeout: Duration = .seconds(10),
  _ condition: @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
}

extension WorkingTreeStatus {
  static func sample(
    _ path: String, entries: [WorkingTreeEntry], lock: IndexLock? = nil,
    observedAt: Date = Date()
  ) -> WorkingTreeStatus {
    var counts = WorkingTreeCounts()
    for entry in entries {
      switch entry.kind {
      case .untracked, .untrackedDirectory: counts.untracked += 1
      case .conflicted: counts.conflicted += 1
      default:
        if entry.isStaged { counts.staged += 1 }
        if entry.isUnstaged { counts.unstaged += 1 }
      }
    }
    return WorkingTreeStatus(
      repositoryPath: path,
      branch: BranchStatus(headRevision: "abc", branchName: "main"),
      entries: entries,
      counts: counts,
      indexLock: lock,
      observedAt: observedAt
    )
  }
}
