import Foundation
import VibeDomain

/// What a repository is on, as the report needs it: `nil` when it cannot be read at all.
public struct RepositoryHead: Hashable, Sendable {
  /// `nil` on a detached `HEAD`.
  public let checkedOutBranch: String?

  public init(checkedOutBranch: String?) {
    self.checkedOutBranch = checkedOutBranch
  }
}

/// Git, read only, for the session report. The application never writes a branch or a worktree:
/// the agent makes those it needs, and this is how the report finds out what it did.
public protocol RepositoryActivityReading: Sendable {
  func head(atPath path: String) async -> RepositoryHead?
  func repositoryRoot(containing path: String) async -> String?
  func reflog(atPath path: String, since date: Date) async -> [ReflogEntry]
  func hasUncommittedChanges(atPath path: String, since date: Date) async -> Bool
}

/// Where an agent worked, as its own transcript tells it.
public struct TranscriptActivity: Hashable, Sendable {
  public var editedPaths: Set<String>
  public var workingDirectories: Set<String>

  public init(editedPaths: Set<String> = [], workingDirectories: Set<String> = []) {
    self.editedPaths = editedPaths
    self.workingDirectories = workingDirectories
  }
}

public protocol SessionTranscriptReading: Sendable {
  func activity(for session: WorkSession) async -> TranscriptActivity?
}

public struct ReflogEntry: Hashable, Sendable {
  public let branch: String
  public let date: Date
  public let subject: String

  public init(branch: String, date: Date, subject: String) {
    self.branch = branch
    self.date = date
    self.subject = subject
  }
}

/// What happened to one branch since the session started.
public struct BranchChange: Hashable, Sendable, Identifiable {
  public enum Kind: String, Hashable, Sendable {
    case created
    case advanced
    case rewritten
  }

  public let name: String
  public let kind: Kind
  public let commitCount: Int?

  public init(name: String, kind: Kind, commitCount: Int?) {
    self.name = name
    self.kind = kind
    self.commitCount = commitCount
  }

  public var id: String { name }

  /// Reads the reflog entries of `branch`: created, moved forward or rewritten.
  public static func fromReflog(branch: String, _ entries: [ReflogEntry]) -> BranchChange? {
    let subjects = entries.filter { $0.branch == branch }.sorted { $0.date < $1.date }.map(
      \.subject)
    guard !subjects.isEmpty else { return nil }
    let commits = subjects.filter { $0.hasPrefix("commit") }.count
    if subjects.contains(where: { $0.hasPrefix("branch: Created") }) {
      return BranchChange(name: branch, kind: .created, commitCount: commits)
    }
    if subjects.contains(where: { $0.hasPrefix("rebase") || $0.hasPrefix("reset:") }) {
      return BranchChange(name: branch, kind: .rewritten, commitCount: commits)
    }
    return BranchChange(name: branch, kind: .advanced, commitCount: commits > 0 ? commits : nil)
  }
}

public struct RepositoryBranchReport: Hashable, Sendable, Identifiable {
  public enum Involvement: Int, Hashable, Sendable, Comparable {
    case worked
    case edited
    case attached

    public static func < (lhs: Involvement, rhs: Involvement) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }

  public let path: String
  public let name: String
  public let involvement: Involvement
  public let checkedOutBranch: String?
  public let change: BranchChange?
  public let isDirty: Bool
  public let isUnreadable: Bool

  public init(
    path: String,
    name: String,
    involvement: Involvement,
    checkedOutBranch: String?,
    change: BranchChange?,
    isDirty: Bool,
    isUnreadable: Bool = false
  ) {
    self.path = path
    self.name = name
    self.involvement = involvement
    self.checkedOutBranch = checkedOutBranch
    self.change = change
    self.isDirty = isDirty
    self.isUnreadable = isUnreadable
  }

  public var id: String { path }

  public var isUnchanged: Bool { change == nil && !isDirty }
}

public struct SessionBranchReport: Hashable, Sendable {
  public let sessionID: SessionID
  public let repositories: [RepositoryBranchReport]
  public let visitedOnly: [String]
  public let hasTranscript: Bool
  public let readAt: Date

  public init(
    sessionID: SessionID,
    repositories: [RepositoryBranchReport],
    visitedOnly: [String] = [],
    hasTranscript: Bool = true,
    readAt: Date
  ) {
    self.sessionID = sessionID
    self.repositories = repositories
    self.visitedOnly = visitedOnly
    self.hasTranscript = hasTranscript
    self.readAt = readAt
  }
}

/// Tells a session which repositories its agent worked in, on which branch, and what moved.
///
/// The repositories come from the session's own transcript, not from the disk: a reflog says what
/// moved, never who moved it, and two sessions in one folder would otherwise be told each other's
/// work. Each path is brought back to the repository — or the worktree the agent made itself —
/// it belongs to.
public struct ReadSessionBranchReport: Sendable {
  private let reader: any RepositoryActivityReading
  private let transcripts: (any SessionTranscriptReading)?
  private let clock: any SessionClock

  public init(
    reader: any RepositoryActivityReading,
    transcripts: (any SessionTranscriptReading)? = nil,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.reader = reader
    self.transcripts = transcripts
    self.clock = clock
  }

  public func callAsFunction(for session: WorkSession) async -> SessionBranchReport {
    let since = session.startedAt ?? session.createdAt
    let activity = await transcripts?.activity(for: session)

    var involvements: [String: RepositoryBranchReport.Involvement] = [:]
    var order: [String] = []
    func note(_ root: String, _ involvement: RepositoryBranchReport.Involvement) {
      if let known = involvements[root] {
        involvements[root] = max(known, involvement)
      } else {
        involvements[root] = involvement
        order.append(root)
      }
    }

    // The folder the session was opened on counts only when it is in a repository: a folder of
    // repositories is where the agent starts, and what it works in is said by the transcript.
    for attached in session.repositories {
      if let root = await reader.repositoryRoot(containing: attached.path) {
        note(root, .attached)
      }
    }
    for path in (activity?.editedPaths ?? []).sorted() {
      if let root = await reader.repositoryRoot(containing: path) { note(root, .edited) }
    }
    for path in (activity?.workingDirectories ?? []).sorted() {
      if let root = await reader.repositoryRoot(containing: path) { note(root, .worked) }
    }

    var reports: [RepositoryBranchReport] = []
    var visited: [String] = []
    for root in order {
      guard let involvement = involvements[root] else { continue }
      let report = await report(root, involvement: involvement, in: session, since: since)
      if involvement == .worked, report.isUnchanged {
        visited.append(report.name)
        continue
      }
      reports.append(report)
    }
    // Stable: the attached repository first, then the others in the order they were met.
    let attached = reports.filter { $0.involvement == .attached }
    let others = reports.filter { $0.involvement != .attached }

    return SessionBranchReport(
      sessionID: session.id,
      repositories: attached + others,
      visitedOnly: visited,
      hasTranscript: activity != nil,
      readAt: clock.now()
    )
  }

  private func report(
    _ root: String,
    involvement: RepositoryBranchReport.Involvement,
    in session: WorkSession,
    since: Date
  ) async -> RepositoryBranchReport {
    let name = Self.name(of: root, in: session)
    guard let head = await reader.head(atPath: root) else {
      return RepositoryBranchReport(
        path: root, name: name, involvement: involvement, checkedOutBranch: nil, change: nil,
        isDirty: false, isUnreadable: true)
    }
    var change: BranchChange?
    if let branch = head.checkedOutBranch {
      change = BranchChange.fromReflog(
        branch: branch, await reader.reflog(atPath: root, since: since))
    }
    return RepositoryBranchReport(
      path: root,
      name: name,
      involvement: involvement,
      checkedOutBranch: head.checkedOutBranch,
      change: change,
      isDirty: await reader.hasUncommittedChanges(atPath: root, since: since)
    )
  }

  /// The repository's name as the user knows it: relative to the folder of the session when it is
  /// under it, its full path otherwise, and a worktree an agent made for itself named after its
  /// clone.
  static func name(of root: String, in session: WorkSession) -> String {
    let canonical = CanonicalPath.of(root)
    var name = (root as NSString).abbreviatingWithTildeInPath
    let owner = session.repositories
      .map { CanonicalPath.of($0.path) }
      .filter { canonical == $0 || canonical.hasPrefix($0 + "/") }
      .max { $0.count < $1.count }
    if let owner {
      name =
        canonical == owner
        ? (owner as NSString).lastPathComponent : String(canonical.dropFirst(owner.count + 1))
    }
    for marker in ["/.claude/worktrees/", "/.codex/worktrees/", "/.worktrees/"] {
      if let range = name.range(of: marker) {
        let clone = String(name[..<range.lowerBound])
        let worktree = String(name[range.upperBound...])
        return "\(clone.isEmpty ? "worktree" : clone) · worktree \(worktree)"
      }
    }
    return name
  }
}
