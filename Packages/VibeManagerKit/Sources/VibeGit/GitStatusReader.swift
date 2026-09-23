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
  private let parser = GitStatusParser()

  /// A runner of its own by default, bounded to 30 s: a repository on a network volume, or a
  /// damaged one, must not keep a reading — and the repository's slot — for two minutes.
  public init(git: any GitCommandRunner = ProcessGitCommandRunner(timeout: .seconds(30))) {
    self.git = git
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
      result = try await git.run(Self.arguments, in: path)
    } catch let unavailable as GitUnavailable {
      return .failure(.gitUnavailable(unavailable))
    } catch {
      return .failure(.failed(summary: error.localizedDescription))
    }
    let duration = clock.now - started

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
    return .success(
      WorkingTreeStatus(
        repositoryPath: path,
        branch: parsed.branch,
        operation: operation,
        entries: parsed.entries,
        counts: parsed.counts,
        isTruncated: parsed.isTruncated,
        indexLock: lock,
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
      return .failure(.failed(summary: "Git did not say where this repository keeps its state."))
    }
    let found = GitDirectories(gitDirectory: lines[0], commonDirectory: lines[1])
    await directories.remember(found, for: path)
    return .success(found)
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

/// Where each repository keeps its state, asked once: it does not move while it is watched, and
/// every reading needs it to tell a rebase from a merge.
actor GitDirectoryCache {
  private var values: [String: GitDirectories] = [:]

  func known(_ path: String) -> GitDirectories? { values[path] }

  func remember(_ directories: GitDirectories, for path: String) {
    values[path] = directories
  }
}
