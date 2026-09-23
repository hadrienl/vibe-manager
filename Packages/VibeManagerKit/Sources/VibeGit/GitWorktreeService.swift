import Foundation
import VibeApplication

/// Creates the worktrees and branches of a session, and nothing else.
///
/// There is no code here that removes a worktree, deletes a branch, prunes a record or deletes a
/// folder, and there must never be: detaching, closing, archiving and failing all forget, and
/// leave the work where it is. The commands that would destroy it are offered to the user as text.
public struct GitWorktreeService: WorktreeCreating {
  private let git: any GitCommandRunner
  private let serializer: GitWriteSerializer

  public init(
    git: any GitCommandRunner = ProcessGitCommandRunner(),
    serializer: GitWriteSerializer = GitWriteSerializer()
  ) {
    self.git = git
    self.serializer = serializer
  }

  public func createSessionFolder(atPath path: String) async throws {
    do {
      try FileManager.default.createDirectory(
        atPath: path, withIntermediateDirectories: true)
    } catch {
      throw WorktreeCreationError(
        message: "The folder \(path) could not be created: \(error.localizedDescription)")
    }
  }

  public func createWorktree(_ request: WorktreeCreationRequest) async throws {
    try await serializer.perform(on: request.commonDirectory) { [git] in
      let reference = "refs/heads/\(request.branchName)"
      let existing = try await git.run(
        ["show-ref", "--verify", "--quiet", reference], in: request.repositoryPath)
      // Read again under the lock: another session prepared a moment ago on this repository may
      // have created the branch between the plan and now.
      if request.createsBranch, existing.succeeded {
        throw WorktreeCreationError(
          message: "The branch \(request.branchName) was created by something else meanwhile.")
      }
      if !request.createsBranch, !existing.succeeded {
        throw WorktreeCreationError(
          message: "The branch \(request.branchName) no longer exists.")
      }

      var arguments = ["worktree", "add"]
      if request.createsBranch {
        arguments += ["-b", request.branchName, request.worktreePath]
        if let base = request.baseRevision { arguments.append(base) }
      } else {
        arguments += [request.worktreePath, request.branchName]
      }
      let result = try await git.run(arguments, in: request.repositoryPath)
      guard result.succeeded else {
        throw WorktreeCreationError(message: result.errorSummary)
      }
    }
  }

  public func createBranchInPlace(
    repositoryPath: String,
    commonDirectory: String,
    branch: String
  ) async throws {
    try await serializer.perform(on: commonDirectory) { [git] in
      let result = try await git.run(["switch", "--create", branch], in: repositoryPath)
      guard result.succeeded else {
        throw WorktreeCreationError(message: result.errorSummary)
      }
    }
  }
}

/// One queue of writes per repository.
///
/// Keyed on the common directory, which is the repository itself whichever worktree it is reached
/// through: two sessions prepared at the same moment on one repository would otherwise meet on
/// `index.lock`, and the error would teach nobody anything. Reads are never queued.
public actor GitWriteSerializer {
  private var tails: [String: Task<Void, Never>] = [:]

  public init() {}

  public func perform<Value: Sendable>(
    on key: String,
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let key = CanonicalPath.of(key)
    let previous = tails[key]
    let task = Task<Value, any Error> {
      await previous?.value
      return try await operation()
    }
    tails[key] = Task { _ = try? await task.value }
    return try await task.value
  }
}
