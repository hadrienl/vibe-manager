import Foundation
import VibeDomain

/// One worktree Git has on record for a repository, as `git worktree list --porcelain` lists it.
public struct GitWorktreeRecord: Hashable, Sendable {
  public let path: String
  public let headRevision: String?
  /// The short name, without `refs/heads/`. `nil` for a detached or bare entry.
  public let branchName: String?
  public let isBare: Bool
  public let isLocked: Bool
  public let lockReason: String?
  /// Git's own word for a record whose folder has disappeared.
  public let isPrunable: Bool

  public init(
    path: String,
    headRevision: String? = nil,
    branchName: String? = nil,
    isBare: Bool = false,
    isLocked: Bool = false,
    lockReason: String? = nil,
    isPrunable: Bool = false
  ) {
    self.path = path
    self.headRevision = headRevision
    self.branchName = branchName
    self.isBare = isBare
    self.isLocked = isLocked
    self.lockReason = lockReason
    self.isPrunable = isPrunable
  }
}

/// A branch and the commit it names.
public struct GitBranchReference: Hashable, Sendable {
  public let name: String
  public let revision: String

  public init(name: String, revision: String) {
    self.name = name
    self.revision = revision
  }
}

/// What a Git repository is right now, read without writing anything.
public struct GitRepositoryFacts: Hashable, Sendable {
  /// The top of the worktree the designated folder belongs to.
  public let topLevelPath: String
  /// The repository itself. Two folders with the same one are the same repository, whichever
  /// worktree or link they were reached through.
  public let commonDirectory: String
  /// `nil` in a repository that has no commit yet.
  public let headRevision: String?
  /// `nil` when `HEAD` is detached.
  public let branchName: String?
  public let isDirty: Bool
  public let hasSubmodules: Bool
  /// What `origin/HEAD` points at, when a remote says so.
  public let defaultBranch: GitBranchReference?
  public let localBranches: Set<String>
  public let worktrees: [GitWorktreeRecord]

  public init(
    topLevelPath: String,
    commonDirectory: String,
    headRevision: String?,
    branchName: String?,
    isDirty: Bool = false,
    hasSubmodules: Bool = false,
    defaultBranch: GitBranchReference? = nil,
    localBranches: Set<String> = [],
    worktrees: [GitWorktreeRecord] = []
  ) {
    self.topLevelPath = topLevelPath
    self.commonDirectory = commonDirectory
    self.headRevision = headRevision
    self.branchName = branchName
    self.isDirty = isDirty
    self.hasSubmodules = hasSubmodules
    self.defaultBranch = defaultBranch
    self.localBranches = localBranches
    self.worktrees = worktrees
  }

  public func worktree(onBranch branch: String) -> GitWorktreeRecord? {
    worktrees.first { $0.branchName == branch }
  }

  public func worktree(atPath path: String) -> GitWorktreeRecord? {
    let canonical = CanonicalPath.of(path)
    return worktrees.first { CanonicalPath.of($0.path) == canonical }
  }
}

/// What a designated folder turned out to be.
public enum RepositoryInspection: Hashable, Sendable {
  /// Missing, not a folder, or closed to the application — the issues `SessionDraftIssue`
  /// already words.
  case unusable(WorkingDirectoryStatus)
  /// A folder with no repository around it.
  case plainFolder
  /// A repository with no working tree: there is nothing to work in, and no worktree to add
  /// from it without a working clone.
  case bare(commonDirectory: String)
  case repository(GitRepositoryFacts)
  /// A folder that holds a repository — it has a `.git` — while `git` itself cannot run.
  case gitUnavailable(GitUnavailable)
}

/// Reads a folder without writing to it: the first step of attaching anything.
public protocol RepositoryInspecting: Sendable {
  func inspect(path: String) async -> RepositoryInspection
}

/// A session's worktrees, as seen from the application: created, never removed.
///
/// There is deliberately no method here that deletes a worktree, a branch or a folder, and no
/// method that prunes. What the application offers in their place is a command to copy.
public protocol WorktreeCreating: Sendable {
  /// Creates the folder the session's worktrees go under. An existing one is left as it is.
  func createSessionFolder(atPath path: String) async throws
  func createWorktree(_ request: WorktreeCreationRequest) async throws
  /// Creates the session's branch in the clone itself, for a repository attached in place with a
  /// detached `HEAD`. The working tree and its changes are carried over, as `git switch -c` does.
  func createBranchInPlace(repositoryPath: String, commonDirectory: String, branch: String)
    async throws
}

public struct WorktreeCreationRequest: Hashable, Sendable {
  public let repositoryPath: String
  /// What the writes are serialised on: two sessions prepared at once on one repository would
  /// otherwise meet on `index.lock`.
  public let commonDirectory: String
  public let worktreePath: String
  public let branchName: String
  /// `false` puts the worktree on a branch that already exists, without `-b`.
  public let createsBranch: Bool
  public let baseRevision: String?

  public init(
    repositoryPath: String,
    commonDirectory: String,
    worktreePath: String,
    branchName: String,
    createsBranch: Bool,
    baseRevision: String?
  ) {
    self.repositoryPath = repositoryPath
    self.commonDirectory = commonDirectory
    self.worktreePath = worktreePath
    self.branchName = branchName
    self.createsBranch = createsBranch
    self.baseRevision = baseRevision
  }
}

/// A write Git refused. Carries Git's own sentence: it is usually the most precise one there is.
public struct WorktreeCreationError: Error, Hashable, Sendable, LocalizedError {
  public let message: String

  public init(message: String) {
    self.message = message
  }

  public var errorDescription: String? { message }
}

/// Where the worktrees of every session go.
///
/// One root, outside every repository — a worktree nested in a clone shows up in its `git status`,
/// in the agent's searches and in its builds — and not beside the repository either, since
/// writing in the parent of a designated folder is an access macOS never granted.
public protocol WorktreeRootProviding: Sendable {
  func worktreeRootPath() async -> String
}

public struct FixedWorktreeRoot: WorktreeRootProviding {
  public static var defaultPath: String {
    (NSHomeDirectory() as NSString).appendingPathComponent("VibeManager/Worktrees")
  }

  private let path: String

  public init(path: String = FixedWorktreeRoot.defaultPath) {
    self.path = path
  }

  public func worktreeRootPath() async -> String { path }
}

/// The worktree root as a setting the user can change, through the open panel.
///
/// Changing it moves nothing: the worktrees already made stay where they were, recorded on their
/// sessions, and only the next ones go to the new place.
public protocol WorktreeRootStoring: WorktreeRootProviding {
  func setWorktreeRootPath(_ path: String) async
  func resetWorktreeRootPath() async
}
