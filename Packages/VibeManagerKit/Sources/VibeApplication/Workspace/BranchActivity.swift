import Foundation
import VibeDomain

/// Reads the branches of a repository, and nothing that writes.
///
/// Called every thirty seconds on a repository an agent may be committing in, so every read
/// takes no optional lock: a report must never be the reason a commit meets `index.lock`.
public protocol RepositoryActivityReading: Sendable {
  /// Every local branch, the branch checked out, `HEAD`, and whether anything is uncommitted.
  /// `nil` when the folder is gone or is no longer a repository.
  func references(atPath path: String) async -> GitReferenceSnapshot?
  /// The top of the worktree a path belongs to — a clone, or one of its worktrees — or `nil`
  /// outside any repository. The path need not exist any more: its nearest folder that does is
  /// asked.
  func repositoryRoot(containing path: String) async -> String?
  /// What the reflogs of the local branches recorded after `date`, oldest first.
  func reflog(atPath path: String, since date: Date) async -> [ReflogEntry]
  /// Whether an uncommitted change was written after `date` — so a repository the user left dirty
  /// days ago is not presented as one the session worked in.
  func hasUncommittedChanges(atPath path: String, since date: Date) async -> Bool
}

/// What an agent's own transcript says it did: the files it edited, the folders it worked from.
///
/// This is the only record that belongs to one session. A repository's reflog says what moved,
/// not who moved it, and two sessions in one folder would otherwise be told each other's work.
public struct TranscriptActivity: Hashable, Sendable {
  /// Files written through the agent's editing tools or patches.
  public var editedPaths: Set<String>
  /// Folders its commands ran from.
  public var workingDirectories: Set<String>

  public init(editedPaths: Set<String> = [], workingDirectories: Set<String> = []) {
    self.editedPaths = editedPaths
    self.workingDirectories = workingDirectories
  }
}

/// Finds and reads the transcripts of a session's agent. `nil` when none can be found — no
/// identifier was ever kept, or the CLI writes them somewhere this does not know.
public protocol SessionTranscriptReading: Sendable {
  func activity(for session: WorkSession) async -> TranscriptActivity?
}

/// One line of a branch's reflog: what moved it, and when.
public struct ReflogEntry: Hashable, Sendable {
  public let branch: String
  public let date: Date
  /// Git's own subject: `commit: …`, `branch: Created from …`, `rebase (finish): …`, `reset: …`.
  public let subject: String

  public init(branch: String, date: Date, subject: String) {
    self.branch = branch
    self.date = date
    self.subject = subject
  }
}

extension BranchChange {
  /// The classification alone, for the tests that hold it to its wording.
  public static func fromReflogForTests(_ entries: [ReflogEntry]) -> BranchChange? {
    guard let branch = entries.first?.branch else { return nil }
    return fromReflog(branch: branch, entries)
  }

  /// What a branch's reflog since the session started says happened to it.
  ///
  /// The reflog is what Git itself keeps of every move, which is what lets a folder of many
  /// repositories be reported without a photograph taken beforehand. A deleted branch takes its
  /// reflog with it, so deletions are not seen this way.
  static func fromReflog(_ entries: [ReflogEntry]) -> [BranchChange] {
    let byBranch = Dictionary(grouping: entries, by: \.branch)
    return byBranch.keys.sorted().compactMap { branch in
      let subjects = (byBranch[branch] ?? []).sorted { $0.date < $1.date }.map(\.subject)
      let commits = subjects.filter { $0.hasPrefix("commit") }.count
      if subjects.contains(where: { $0.hasPrefix("branch: Created") || $0.hasPrefix("checkout:") })
      {
        return BranchChange(name: branch, kind: .created, commitCount: commits)
      }
      if subjects.contains(where: { $0.hasPrefix("rebase") || $0.hasPrefix("reset:") }) {
        return BranchChange(name: branch, kind: .rewritten, commitCount: commits)
      }
      guard !subjects.isEmpty else { return nil }
      return BranchChange(name: branch, kind: .advanced, commitCount: commits > 0 ? commits : nil)
    }
  }
}

extension BranchChange {
  /// What a branch's reflog since the session started says happened to it.
  static func fromReflog(branch: String, _ entries: [ReflogEntry]) -> BranchChange? {
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

/// One thing that happened to a branch since the session's first launch.
public struct BranchChange: Hashable, Sendable, Identifiable {
  public enum Kind: String, Hashable, Sendable {
    /// The branch did not exist when the session started.
    case created
    /// It moved forward: its old commit is still in its history.
    case advanced
    /// It moved elsewhere: its old commit is no longer in its history — a rebase, a reset.
    case rewritten
    /// It existed, and does no more.
    case deleted
  }

  public let name: String
  public let kind: Kind
  /// Commits on it that the session's start did not have. `nil` for a deleted branch, and when
  /// Git could not count them.
  public let commitCount: Int?

  public init(name: String, kind: Kind, commitCount: Int?) {
    self.name = name
    self.kind = kind
    self.commitCount = commitCount
  }

  public var id: String { name }

  public var sentence: String {
    // No commit yet is said by saying nothing: "created, 0 commits" reads like a failure.
    let commits = commitCount.flatMap { $0 == 0 ? nil : ($0 == 1 ? "1 commit" : "\($0) commits") }
    switch kind {
    case .created:
      return commits.map { "created, \($0)" } ?? "created"
    case .advanced:
      return commits.map { "+\($0)" } ?? "moved forward"
    case .rewritten:
      return commits.map { "rewritten, \($0) new" } ?? "rewritten"
    case .deleted:
      return "deleted"
    }
  }
}

/// One repository — or worktree — the session worked in, and the branch it worked on.
public struct RepositoryBranchReport: Hashable, Sendable, Identifiable {
  /// How the session came to be in this repository.
  public enum Involvement: Int, Hashable, Sendable, Comparable {
    /// Its commands ran here, and something moved.
    case worked
    /// Its agent edited files here.
    case edited
    /// It is attached to the session.
    case attached

    public static func < (lhs: Involvement, rhs: Involvement) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }

  /// The attached folder this repository is, or lies in. `nil` for one outside all of them.
  public let repositoryID: RepositoryID?
  public let path: String
  public let name: String
  public let involvement: Involvement
  public let checkedOutBranch: String?
  /// What happened to the branch checked out, since the session started. Only that branch: the
  /// others may be moved by anyone, and saying so here would credit this session with their work.
  public let change: BranchChange?
  /// Uncommitted changes written since the session started.
  public let isDirty: Bool
  /// The folder could not be read as a repository just now.
  public let isUnreadable: Bool

  public init(
    repositoryID: RepositoryID?,
    path: String,
    name: String,
    involvement: Involvement,
    checkedOutBranch: String?,
    change: BranchChange?,
    isDirty: Bool,
    isUnreadable: Bool = false
  ) {
    self.repositoryID = repositoryID
    self.path = path
    self.name = name
    self.involvement = involvement
    self.checkedOutBranch = checkedOutBranch
    self.change = change
    self.isDirty = isDirty
    self.isUnreadable = isUnreadable
  }

  public var id: String { path }

  public var changes: [BranchChange] { change.map { [$0] } ?? [] }

  public var isUnchanged: Bool { change == nil && !isDirty }
}

public struct SessionBranchReport: Hashable, Sendable {
  public let sessionID: SessionID
  /// Attached repositories first, in their order, then the others the session worked in.
  public let repositories: [RepositoryBranchReport]
  /// Repositories the agent only looked around in — commands ran there, nothing moved. Named, not
  /// detailed: that it went there is worth knowing, and no more.
  public let visitedOnly: [String]
  /// `false` when no transcript of the session could be read: only the attached repositories
  /// are then known, and the inspector says so.
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

  /// The attached repository's own report, when it is a repository.
  public func report(for id: RepositoryID, path: String?) -> RepositoryBranchReport? {
    repositories.first { $0.repositoryID == id && $0.involvement == .attached }
      ?? path.flatMap { path in repositories.first { $0.path == CanonicalPath.of(path) } }
  }

  /// The repositories inside an attached folder that the session worked in.
  public func found(in id: RepositoryID) -> [RepositoryBranchReport] {
    repositories.filter { $0.repositoryID == id && $0.involvement != .attached }
  }

  /// Those outside every attached folder.
  public var elsewhere: [RepositoryBranchReport] {
    repositories.filter { $0.repositoryID == nil }
  }
}

/// Takes the photograph a session's report is measured against, when an agent starts.
///
/// Once per repository, at the first launch that finds none: a restart must not reset what the
/// session has done so far to nothing. The branch of a repository worked in place is written down
/// at every launch, though — it is what the inspector says the session works on, and a session
/// stored before branches were recorded had none.
public struct CaptureSessionBaseline: Sendable {
  private let repository: any SessionRepository
  private let reader: any RepositoryActivityReading

  public init(repository: any SessionRepository, reader: any RepositoryActivityReading) {
    self.repository = repository
    self.reader = reader
  }

  public func callAsFunction(sessionID: SessionID) async {
    guard let session = try? await repository.session(id: sessionID) else { return }
    var snapshots: [RepositoryID: GitReferenceSnapshot] = [:]
    for attached in session.repositories where attached.mode != .plainFolder {
      guard let path = attached.effectivePath,
        let snapshot = await reader.references(atPath: path)
      else { continue }
      snapshots[attached.id] = snapshot
    }
    guard !snapshots.isEmpty else { return }
    let read = snapshots
    _ = try? await repository.mutate(id: sessionID) { stored in
      for index in stored.repositories.indices {
        let id = stored.repositories[index].id
        guard let snapshot = read[id] else { continue }
        if stored.repositories[index].baseline == nil {
          stored.repositories[index].baseline = snapshot
        }
        if stored.repositories[index].mode == .inPlace {
          stored.repositories[index].branchName = snapshot.checkedOutBranch
        }
      }
    }
  }
}

/// Says, repository by repository, where the session worked and on which branch.
///
/// The repositories come from the session's own transcript — the files its agent edited, the
/// folders its commands ran from — and from the ones attached to it. Each is brought back to the
/// worktree it belongs to, hidden ones included: an agent that makes itself a worktree under
/// `.claude/worktrees` has worked there, not in the clone. Then, for each, what its checked-out
/// branch did since the session started, and what is uncommitted since.
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
    // Since the session first ran: what it did over its whole life, not since the last restart.
    let since = session.startedAt ?? session.createdAt
    let activity = await transcripts?.activity(for: session)

    // Every repository, with the strongest reason the session has to be there.
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

    var unreadableAttached: [RepositoryContext] = []
    for attached in session.repositories {
      guard attached.mode != .plainFolder, let path = attached.effectivePath else { continue }
      if let root = await reader.repositoryRoot(containing: path) {
        note(root, .attached)
      } else if attached.mode == .worktree || attached.baseline != nil {
        unreadableAttached.append(attached)
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
      // A folder the agent only passed through is named, not reported: nothing it did there moved.
      if involvement == .worked, report.isUnchanged {
        visited.append(report.name)
        continue
      }
      reports.append(report)
    }
    for attached in unreadableAttached {
      reports.append(
        RepositoryBranchReport(
          repositoryID: attached.id, path: attached.effectivePath ?? attached.rootPath,
          name: attached.displayName, involvement: .attached, checkedOutBranch: nil,
          change: nil, isDirty: false, isUnreadable: true))
    }
    reports.sort { lhs, rhs in
      if (lhs.involvement == .attached) != (rhs.involvement == .attached) {
        return lhs.involvement == .attached
      }
      return false
    }

    return SessionBranchReport(
      sessionID: session.id,
      repositories: reports,
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
    let owner = Self.owner(of: root, in: session)
    let name = Self.name(of: root, under: owner)
    guard let current = await reader.references(atPath: root) else {
      return RepositoryBranchReport(
        repositoryID: owner?.id, path: root, name: name, involvement: involvement,
        checkedOutBranch: nil, change: nil, isDirty: false, isUnreadable: true)
    }
    var change: BranchChange?
    if let branch = current.checkedOutBranch {
      change = BranchChange.fromReflog(
        branch: branch, await reader.reflog(atPath: root, since: since))
    }
    return RepositoryBranchReport(
      repositoryID: owner?.id,
      path: root,
      name: name,
      involvement: involvement,
      checkedOutBranch: current.checkedOutBranch,
      change: change,
      isDirty: await reader.hasUncommittedChanges(atPath: root, since: since)
    )
  }

  /// The attached folder a repository is, or lies in — the deepest one, for folders nested in
  /// each other.
  static func owner(of root: String, in session: WorkSession) -> RepositoryContext? {
    let canonical = CanonicalPath.of(root)
    return session.repositories
      .compactMap { attached -> (RepositoryContext, String)? in
        let base = CanonicalPath.of(attached.effectivePath ?? attached.rootPath)
        return canonical == base || canonical.hasPrefix(base + "/") ? (attached, base) : nil
      }
      .max { $0.1.count < $1.1.count }?.0
  }

  /// A repository named from the folder that holds it, and a worktree an agent made for itself
  /// named after the clone it belongs to.
  static func name(of root: String, under owner: RepositoryContext?) -> String {
    var name = (root as NSString).abbreviatingWithTildeInPath
    if let owner {
      let base = CanonicalPath.of(owner.effectivePath ?? owner.rootPath)
      let canonical = CanonicalPath.of(root)
      name =
        canonical == base
        ? owner.displayName : String(canonical.dropFirst(base.count + 1))
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
