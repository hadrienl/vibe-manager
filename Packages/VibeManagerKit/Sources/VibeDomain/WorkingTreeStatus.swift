import Foundation

/// What happened to a file on one side of Git — the index or the working tree.
public enum FileChange: Hashable, Sendable {
  case added
  case modified
  case deleted
  case typeChanged
  case renamed(from: String, similarity: Int)
  case copied(from: String, similarity: Int)
}

/// The two sides of a merge that disagree about a file, as `git status` names them.
public enum ConflictKind: String, Hashable, Sendable {
  case bothModified
  case bothAdded
  case bothDeleted
  case addedByUs
  case addedByThem
  case deletedByUs
  case deletedByThem
}

/// What changed inside a submodule, as its three flags say.
public struct SubmoduleChange: OptionSet, Hashable, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let commitChanged = SubmoduleChange(rawValue: 1 << 0)
  public static let trackedChanges = SubmoduleChange(rawValue: 1 << 1)
  public static let untrackedChanges = SubmoduleChange(rawValue: 1 << 2)
}

/// One line of `git status`.
///
/// A tracked file keeps Git's two columns rather than one status: a file staged and then changed
/// again (`MM`) is both, and folding it into one word would hide either what is about to be
/// committed or what is not.
public struct WorkingTreeEntry: Hashable, Sendable, Identifiable {
  public enum Kind: Hashable, Sendable {
    case tracked(staged: FileChange?, unstaged: FileChange?)
    case conflicted(ConflictKind)
    case untracked
    /// A folder Git reports as a whole, because nothing in it is tracked.
    case untrackedDirectory
    case submodule(staged: FileChange?, unstaged: FileChange?, SubmoduleChange)
  }

  /// Relative to the root of the repository, exactly as Git wrote it: it is the key a list keeps
  /// its selection by, so it must come back identical from one reading to the next.
  public let path: String
  public let kind: Kind

  public init(path: String, kind: Kind) {
    self.path = path
    self.kind = kind
  }

  public var id: String { path }

  public var isStaged: Bool {
    switch kind {
    case .tracked(let staged, _), .submodule(let staged, _, _): return staged != nil
    case .conflicted, .untracked, .untrackedDirectory: return false
    }
  }

  public var isUnstaged: Bool {
    switch kind {
    case .tracked(_, let unstaged), .submodule(_, let unstaged, _): return unstaged != nil
    case .conflicted, .untracked, .untrackedDirectory: return false
    }
  }
}

/// How many entries of each kind a repository has — exact, even when the list was cut short.
public struct WorkingTreeCounts: Hashable, Sendable {
  public var staged: Int
  public var unstaged: Int
  public var untracked: Int
  public var conflicted: Int

  public init(staged: Int = 0, unstaged: Int = 0, untracked: Int = 0, conflicted: Int = 0) {
    self.staged = staged
    self.unstaged = unstaged
    self.untracked = untracked
    self.conflicted = conflicted
  }

  public var isEmpty: Bool { staged == 0 && unstaged == 0 && untracked == 0 && conflicted == 0 }
}

/// The branch a repository is on, and how far it is from its upstream by the local references.
public struct BranchStatus: Hashable, Sendable {
  /// `nil` before the first commit.
  public let headRevision: String?
  /// `nil` on a detached `HEAD`.
  public let branchName: String?
  public let upstream: String?
  /// `nil` without an upstream. Counted against the references on disk: nothing is fetched.
  public let ahead: Int?
  public let behind: Int?

  public init(
    headRevision: String? = nil,
    branchName: String? = nil,
    upstream: String? = nil,
    ahead: Int? = nil,
    behind: Int? = nil
  ) {
    self.headRevision = headRevision
    self.branchName = branchName
    self.upstream = upstream
    self.ahead = ahead
    self.behind = behind
  }
}

/// An operation Git left half done — the state most worth seeing, and one `status --porcelain`
/// does not say.
public enum RepositoryOperation: String, Hashable, Sendable {
  case merging
  case rebasing
  case cherryPicking
  case reverting
  case bisecting
}

/// Another Git process holding the index, and since when.
public struct IndexLock: Hashable, Sendable {
  public let path: String
  public let since: Date

  public init(path: String, since: Date) {
    self.path = path
    self.since = since
  }
}

/// What `git status` said about one repository, at one moment. Never stored: it is only true for
/// as long as nothing moves on the disk.
public struct WorkingTreeStatus: Hashable, Sendable {
  public let repositoryPath: String
  public let branch: BranchStatus
  public let operation: RepositoryOperation?
  /// At most the reader's limit, in Git's order.
  public let entries: [WorkingTreeEntry]
  public let counts: WorkingTreeCounts
  public let isTruncated: Bool
  public let indexLock: IndexLock?
  public let observedAt: Date
  public let duration: Duration

  public init(
    repositoryPath: String,
    branch: BranchStatus,
    operation: RepositoryOperation? = nil,
    entries: [WorkingTreeEntry],
    counts: WorkingTreeCounts,
    isTruncated: Bool = false,
    indexLock: IndexLock? = nil,
    observedAt: Date,
    duration: Duration = .zero
  ) {
    self.repositoryPath = repositoryPath
    self.branch = branch
    self.operation = operation
    self.entries = entries
    self.counts = counts
    self.isTruncated = isTruncated
    self.indexLock = indexLock
    self.observedAt = observedAt
    self.duration = duration
  }

  public var isClean: Bool { counts.isEmpty }

  /// Whether two readings describe the same repository, whenever and however fast they were
  /// made. A reading that only moved the clock is not news, and publishing it would redraw a list
  /// for nothing.
  public func hasSameContent(as other: WorkingTreeStatus) -> Bool {
    repositoryPath == other.repositoryPath && branch == other.branch
      && operation == other.operation && entries == other.entries && counts == other.counts
      && isTruncated == other.isTruncated && indexLock == other.indexLock
  }
}
