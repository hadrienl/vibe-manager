import Foundation
import VibeApplication
import VibeDomain

/// Reads a repository's working tree with one `git status`, and never writes in it.
///
/// `--no-optional-locks` on top of the `GIT_OPTIONAL_LOCKS=0` the runner already sets, on purpose:
/// without it `git status` rewrites the index to refresh its stat data, takes `index.lock` to do
/// it, and the agent committing at that moment fails on a lock that is ours.
public struct GitStatusReader: RepositoryStatusReading {
  private let git: any GitCommandRunner
  private let directories = GitDirectoryCache()
  private let commits = BranchCommitsCache()
  private let parser = GitStatusParser()
  private let commitsRetryDelay: Duration

  /// A runner of its own by default, bounded to 30 s: a repository on a network volume, or a
  /// damaged one, must not keep a reading — and the repository's slot — for two minutes.
  ///
  /// `commitsRetryDelay` is how long a diff that failed is left alone before it is tried again for
  /// the same revisions; the wait doubles at each new failure.
  public init(
    git: any GitCommandRunner = ProcessGitCommandRunner(timeout: .seconds(30)),
    commitsRetryDelay: Duration = .seconds(60)
  ) {
    self.git = git
    self.commitsRetryDelay = commitsRetryDelay
  }

  public static let arguments = [
    "--no-optional-locks", "status", "--porcelain=v2", "-z", "--branch",
    "--untracked-files=normal", "--find-renames",
  ]

  public func status(atPath path: String, limit: Int) async -> Result<
    WorkingTreeStatus, RepositoryStatusIssue
  > {
    if let refused = Self.accessIssue(at: path) { return .failure(refused) }

    let clock = ContinuousClock()
    let started = clock.now
    let result: GitCommandResult
    do {
      result = try await Signposts.interval("git.status") {
        try await git.run(Self.arguments, in: path)
      }
    } catch let unavailable as GitUnavailable {
      return .failure(.gitUnavailable(unavailable))
    } catch {
      return .failure(.failed(summary: error.localizedDescription))
    }
    var duration = clock.now - started

    guard result.succeeded else {
      // The runner answers -1 when it had to stop a Git that would not finish.
      if result.exitCode == -1 { return .failure(.timedOut(after: duration)) }
      return .failure(RepositoryStatusIssue.classify(errorOutput: result.errorOutput, path: path))
    }

    let parsed = parser.parse(result.output, limit: limit)
    var operation: RepositoryOperation?
    var lock: IndexLock?
    if case .success(let found) = await gitDirectories(atPath: path) {
      operation = Self.operation(in: found.gitDirectory)
      lock = Self.indexLock(in: found.gitDirectory)
    }
    let committed = await branchCommits(
      atPath: path, branch: parsed.branch.branchName, head: parsed.branch.headRevision,
      limit: limit)
    // What the monitor paces its readings by: the commits read beside the status cost as much.
    duration = clock.now - started
    return .success(
      WorkingTreeStatus(
        repositoryPath: path,
        branch: parsed.branch,
        operation: operation,
        entries: parsed.entries,
        counts: parsed.counts,
        isTruncated: parsed.isTruncated,
        indexLock: lock,
        committed: committed,
        observedAt: Date(),
        duration: duration
      ))
  }

  public func gitDirectories(atPath path: String) async -> Result<
    GitDirectories, RepositoryStatusIssue
  > {
    if let known = await directories.known(path) { return .success(known) }
    if let refused = Self.accessIssue(at: path) { return .failure(refused) }
    let result: GitCommandResult
    do {
      result = try await git.run(
        ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: path)
    } catch let unavailable as GitUnavailable {
      return .failure(.gitUnavailable(unavailable))
    } catch {
      return .failure(.failed(summary: error.localizedDescription))
    }
    guard result.succeeded else {
      return .failure(RepositoryStatusIssue.classify(errorOutput: result.errorOutput, path: path))
    }
    let lines = result.text.split(separator: "\n").map(String.init)
    guard lines.count == 2 else {
      return .failure(
        .failed(
          summary: String(
            localized: "Git did not say where this repository keeps its state.", bundle: .module)))
    }
    let found = GitDirectories(gitDirectory: lines[0], commonDirectory: lines[1])
    await directories.remember(found, for: path)
    return .success(found)
  }

  /// The references a branch is compared with, best first: the remote's default branch as the
  /// clone recorded it, the usual names of it, then the local ones of a repository without remote.
  static let baseReferences = [
    "refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master",
    "refs/heads/main", "refs/heads/master",
  ]

  /// What the branch committed since it left its base. One `for-each-ref` at every reading; the
  /// diff itself only when `HEAD` or the base moved, because a file saved moves neither.
  ///
  /// A Git that failed — timed out on a large diff, a shallow clone without the merge base — is not
  /// "nothing committed": the last list read on this branch stays. It is not tried again for the
  /// same revisions before a wait that doubles at each failure: a diff that takes Git more than its
  /// 30 s would otherwise hold every reading, and the repository's slot, that long.
  func branchCommits(atPath path: String, branch: String?, head: String?, limit: Int) async
    -> BranchCommits?
  {
    guard let head else {
      await commits.forget(path)
      return nil
    }
    guard
      let references = try? await git.run(
        ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)"]
          + Self.baseReferences, in: path),
      references.succeeded
    else { return await commits.last(path, branch: branch, head: head) }
    guard let base = Self.base(from: references.text) else {
      await commits.forget(path)
      return nil
    }
    let key = BranchCommitsCache.Key(head: head, base: base.name, baseRevision: base.revision)
    if let known = await commits.known(path, key) { return known }
    guard await commits.mayRetry(path, key, at: .now) else {
      return await commits.last(path, branch: branch, head: head)
    }
    guard let value = await readBranchCommits(atPath: path, head: head, base: base, limit: limit)
    else {
      await commits.failed(path, key, at: .now, firstDelay: commitsRetryDelay)
      return await commits.last(path, branch: branch, head: head)
    }
    await commits.remember(value, for: path, key, branch: branch)
    return value
  }

  /// `.some(nil)` when the branch has nothing the base lacks; `nil` when Git failed to say.
  private func readBranchCommits(
    atPath path: String, head: String, base: (name: String, revision: String), limit: Int
  ) async -> BranchCommits?? {
    guard
      let mergeBase = try? await git.run(["merge-base", base.revision, head], in: path),
      mergeBase.succeeded, !mergeBase.text.isEmpty
    else { return nil }
    let fork = mergeBase.text
    guard fork != head else { return .some(nil) }
    guard let count = try? await git.run(["rev-list", "--count", "\(fork)..\(head)"], in: path),
      count.succeeded, let commitCount = Int(count.text)
    else { return nil }
    guard commitCount > 0 else { return .some(nil) }
    guard
      let diff = try? await git.run(
        [
          "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--name-status", "-z",
          "--find-renames", fork, head,
        ], in: path),
      diff.succeeded
    else { return nil }
    let (files, total) = GitDiffParser.parse(diff.output, limit: limit)
    return BranchCommits(
      base: base.name, mergeBase: fork, commitCount: commitCount, files: files, totalCount: total)
  }

  /// The first of `baseReferences` that exists, from `for-each-ref`'s records. `origin/HEAD` is
  /// named after the branch it points to: `origin/main`, never `origin/HEAD`.
  static func base(from output: String) -> (name: String, revision: String)? {
    var found: [String: (revision: String, target: String)] = [:]
    for line in output.split(separator: "\n") {
      let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 3, !fields[1].isEmpty else { continue }
      found[fields[0]] = (fields[1], fields[2])
    }
    for reference in baseReferences {
      guard let match = found[reference] else { continue }
      let name = match.target.isEmpty ? reference : match.target
      return (shortName(name), match.revision)
    }
    return nil
  }

  static func shortName(_ reference: String) -> String {
    for prefix in ["refs/remotes/", "refs/heads/"] where reference.hasPrefix(prefix) {
      return String(reference.dropFirst(prefix.count))
    }
    return reference
  }

  /// `git status` narrowed to one untracked folder, with every file in it listed rather than the
  /// folder itself. The pathspec is literal: a folder named `[draft]*` means that folder, not a
  /// pattern.
  public func untrackedFiles(in directory: String, atPath path: String, limit: Int) async
    -> Result<UntrackedListing, RepositoryStatusIssue>
  {
    if let refused = Self.accessIssue(at: path) { return .failure(refused) }
    let result: GitCommandResult
    do {
      result = try await git.run(Self.untrackedArguments(for: directory), in: path)
    } catch let unavailable as GitUnavailable {
      return .failure(.gitUnavailable(unavailable))
    } catch {
      return .failure(.failed(summary: error.localizedDescription))
    }
    guard result.succeeded else {
      if result.exitCode == -1 { return .failure(.timedOut(after: .seconds(30))) }
      return .failure(RepositoryStatusIssue.classify(errorOutput: result.errorOutput, path: path))
    }
    let parsed = parser.parse(result.output, limit: limit)
    return .success(
      UntrackedListing(
        directory: directory,
        paths: parsed.entries.filter { $0.kind == .untracked || $0.kind == .untrackedDirectory }
          .map(\.path),
        totalCount: parsed.counts.untracked))
  }

  static func untrackedArguments(for directory: String) -> [String] {
    [
      "--no-optional-locks", "status", "--porcelain=v2", "-z", "--untracked-files=all",
      "--", ":(literal)" + directory,
    ]
  }

  /// Said before Git is run: a folder that is gone or closed to us would otherwise surface as a
  /// Git that "could not be started", which is true and useless.
  static func accessIssue(at path: String) -> RepositoryStatusIssue? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return .missing(path: path) }
    guard access(path, R_OK | X_OK) == 0 else { return .permissionDenied(path: path) }
    return nil
  }

  static func operation(in gitDirectory: String) -> RepositoryOperation? {
    let manager = FileManager.default
    func exists(_ name: String) -> Bool {
      manager.fileExists(atPath: (gitDirectory as NSString).appendingPathComponent(name))
    }
    if exists("rebase-merge") || exists("rebase-apply") { return .rebasing }
    if exists("MERGE_HEAD") { return .merging }
    if exists("CHERRY_PICK_HEAD") { return .cherryPicking }
    if exists("REVERT_HEAD") { return .reverting }
    if exists("BISECT_LOG") { return .bisecting }
    return nil
  }

  static func indexLock(in gitDirectory: String) -> IndexLock? {
    let path = (gitDirectory as NSString).appendingPathComponent("index.lock")
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let created = attributes[.creationDate] as? Date ?? attributes[.modificationDate] as? Date
    else { return nil }
    return IndexLock(path: path, since: created)
  }
}

/// The last committed files of each repository, the two revisions they were read between and the
/// branch they were read on; and the revisions Git last failed to read, with when to try again.
actor BranchCommitsCache {
  struct Key: Hashable {
    let head: String
    let base: String
    let baseRevision: String
  }

  private struct Entry {
    let key: Key
    let branch: String?
    let value: BranchCommits?
  }

  private struct Failure {
    let key: Key
    let delay: Duration
    let retryAt: ContinuousClock.Instant
  }

  /// The longest a failed diff is left alone: a repository that grew past Git's 30 s can shrink.
  static let longestRetryDelay: Duration = .seconds(30 * 60)

  private var values: [String: Entry] = [:]
  private var failures: [String: Failure] = [:]

  /// `.some(nil)` is an answer too: nothing committed since the base.
  func known(_ path: String, _ key: Key) -> BranchCommits?? {
    guard let entry = values[path], entry.key == key else { return nil }
    return .some(entry.value)
  }

  /// What is shown while Git fails: the last list read, if it was read on this branch — a commit
  /// since does not make it wrong, a checkout does. A detached `HEAD` has no branch to go by, so
  /// only a list read at this very commit stands in.
  func last(_ path: String, branch: String?, head: String) -> BranchCommits? {
    guard let entry = values[path], entry.branch == branch else { return nil }
    guard branch != nil || entry.key.head == head else { return nil }
    return entry.value
  }

  func remember(_ value: BranchCommits?, for path: String, _ key: Key, branch: String?) {
    values[path] = Entry(key: key, branch: branch, value: value)
    failures[path] = nil
  }

  /// False while the wait set by the last failure on these same revisions runs.
  func mayRetry(_ path: String, _ key: Key, at now: ContinuousClock.Instant) -> Bool {
    guard let failure = failures[path], failure.key == key else { return true }
    return now >= failure.retryAt
  }

  /// A first failure on these revisions waits `firstDelay`; each next one twice the last wait.
  func failed(
    _ path: String, _ key: Key, at now: ContinuousClock.Instant, firstDelay: Duration
  ) {
    var delay = firstDelay
    if let previous = failures[path], previous.key == key {
      delay = min(previous.delay * 2, Self.longestRetryDelay)
    }
    failures[path] = Failure(key: key, delay: delay, retryAt: now + delay)
  }

  func forget(_ path: String) {
    values[path] = nil
    failures[path] = nil
  }
}

/// Where each repository keeps its state, asked once: it does not move while it is watched, and
/// every reading needs it to tell a rebase from a merge.
actor GitDirectoryCache {
  private var values: [String: GitDirectories] = [:]

  func known(_ path: String) -> GitDirectories? { values[path] }

  func remember(_ directories: GitDirectories, for path: String) {
    values[path] = directories
  }
}
