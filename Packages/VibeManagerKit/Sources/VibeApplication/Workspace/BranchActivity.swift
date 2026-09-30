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
  /// What the disk says of the repository's references, read without running Git once its
  /// folders are known. `nil` when it cannot be told: the branches are then read again.
  func referenceFingerprint(atPath path: String) async -> ReferenceFingerprint?
}

extension RepositoryActivityReading {
  public func referenceFingerprint(atPath path: String) async -> ReferenceFingerprint? { nil }
}

/// The files Git writes whenever a reference moves, as `stat` sees them: `HEAD`, the reflogs, the
/// loose and packed branches, the reftable. Two equal fingerprints mean no branch moved, no
/// `HEAD` changed and no reflog grew, so what was read of them still holds.
///
/// Compared for equality only, never for order: neither the granularity of a date nor a clock
/// that moved back can make a file look older than it is.
public struct ReferenceFingerprint: Hashable, Sendable {
  public struct Stamp: Hashable, Sendable {
    public let inode: UInt64
    public let size: Int64
    /// In nanoseconds since 1970.
    public let modified: Int64

    public init(inode: UInt64, size: Int64, modified: Int64) {
      self.inode = inode
      self.size = size
      self.modified = modified
    }
  }

  /// Keyed by where the file is, relative to Git's folders: a file that appears or disappears
  /// changes the fingerprint as much as one that is rewritten.
  public let stamps: [String: Stamp]

  public init(stamps: [String: Stamp]) {
    self.stamps = stamps
  }
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

  /// Whether two readings say the same thing, whenever they were made. A reading that only moved
  /// the clock is not news, and publishing it would redraw the Git section for nothing.
  public func hasSameContent(as other: SessionBranchReport) -> Bool {
    sessionID == other.sessionID && repositories == other.repositories
      && visitedOnly == other.visitedOnly && hasTranscript == other.hasTranscript
  }

  /// The same report, as checked again at `date`.
  public func checked(at date: Date) -> SessionBranchReport {
    SessionBranchReport(
      sessionID: sessionID, repositories: repositories, visitedOnly: visitedOnly,
      hasTranscript: hasTranscript, readAt: date)
  }
}

/// Tells a session which repositories its agent worked in, on which branch, and what moved.
///
/// The repositories come from the session's own transcript, not from the disk: a reflog says what
/// moved, never who moved it, and two sessions in one folder would otherwise be told each other's
/// work. Each path is brought back to the repository — or the worktree the agent made itself —
/// it belongs to.
///
/// Read again each time the agent's transcript grows, so Git runs only when an answer may have
/// changed: the branches when the fingerprint of the references moved, the working tree from the
/// status the monitor already keeps — or, for a repository it does not watch, at most every
/// `unwatchedStatusInterval`. A forced reading — the user asked, came back, or the agent stopped —
/// reads everything again.
public struct ReadSessionBranchReport: Sendable {
  /// The last status the monitor read of a repository of a session, when it watches it.
  public typealias KnownStatus = @Sendable (SessionID, String) async -> WorkingTreeStatus?

  private let reader: any RepositoryActivityReading
  private let transcripts: (any SessionTranscriptReading)?
  private let clock: any SessionClock
  private let knownStatus: KnownStatus?
  private let unwatchedStatusInterval: TimeInterval
  private let facts = RepositoryFactsCache()

  public init(
    reader: any RepositoryActivityReading,
    transcripts: (any SessionTranscriptReading)? = nil,
    clock: any SessionClock = SystemSessionClock(),
    knownStatus: KnownStatus? = nil,
    unwatchedStatusInterval: TimeInterval = 30
  ) {
    self.reader = reader
    self.transcripts = transcripts
    self.clock = clock
    self.knownStatus = knownStatus
    self.unwatchedStatusInterval = unwatchedStatusInterval
  }

  public func callAsFunction(for session: WorkSession, forced: Bool = false) async
    -> SessionBranchReport
  {
    let state = Signposts.begin("branchReport.read")
    defer { Signposts.end("branchReport.read", state) }
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
      let report = await report(
        root, involvement: involvement, in: session, since: since, forced: forced)
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
    since: Date,
    forced: Bool
  ) async -> RepositoryBranchReport {
    let name = Self.name(of: root, in: session)
    let key = RepositoryFactsCache.Key(root: root, since: since)
    guard let references = await references(of: root, key: key, since: since, forced: forced)
    else {
      await facts.forget(key)
      return RepositoryBranchReport(
        path: root, name: name, involvement: involvement, checkedOutBranch: nil, change: nil,
        isDirty: false, isUnreadable: true)
    }
    return RepositoryBranchReport(
      path: root,
      name: name,
      involvement: involvement,
      checkedOutBranch: references.head.checkedOutBranch,
      change: references.change,
      isDirty: await isDirty(root, key: key, of: session, since: since, forced: forced)
    )
  }

  /// What is checked out and how it moved: read again only when the references did.
  ///
  /// The fingerprint is taken before Git is run, so that a branch that moves during the reading
  /// leaves a fingerprint that no longer matches, and is read again next time.
  private func references(
    of root: String, key: RepositoryFactsCache.Key, since: Date, forced: Bool
  ) async -> RepositoryFactsCache.References? {
    let fingerprint = await reader.referenceFingerprint(atPath: root)
    if !forced, let fingerprint, let known = await facts.references(for: key),
      known.fingerprint == fingerprint
    {
      return known
    }
    guard let head = await reader.head(atPath: root) else { return nil }
    var change: BranchChange?
    if let branch = head.checkedOutBranch {
      change = BranchChange.fromReflog(
        branch: branch, await reader.reflog(atPath: root, since: since))
    }
    let read = RepositoryFactsCache.References(fingerprint: fingerprint, head: head, change: change)
    if fingerprint != nil { await facts.remember(read, for: key) }
    return read
  }

  /// Whether the agent left work uncommitted: from the monitor's own status when it watches the
  /// repository, so that `git status` runs once for both; otherwise with a status of its own, at
  /// most every `unwatchedStatusInterval`.
  private func isDirty(
    _ root: String, key: RepositoryFactsCache.Key, of session: WorkSession, since: Date,
    forced: Bool
  ) async -> Bool {
    let known = await facts.workingTree(for: key)
    if !forced, let knownStatus, let status = await knownStatus(session.id, root) {
      if let known, known.observedAt == status.observedAt { return known.isDirty }
      if let answer = status.hasChanges(since: since) {
        await facts.remember(
          RepositoryFactsCache.WorkingTree(
            isDirty: answer, observedAt: status.observedAt, checkedAt: clock.now()), for: key)
        return answer
      }
    }
    if !forced, let known, known.observedAt == nil,
      clock.now().timeIntervalSince(known.checkedAt) < unwatchedStatusInterval
    {
      return known.isDirty
    }
    let answer = await reader.hasUncommittedChanges(atPath: root, since: since)
    await facts.remember(
      RepositoryFactsCache.WorkingTree(isDirty: answer, observedAt: nil, checkedAt: clock.now()),
      for: key)
    return answer
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

/// What was last read of each repository for each session, and what it was read from: the
/// fingerprint of the references for the branches, the monitor's reading or the clock for the
/// working tree.
actor RepositoryFactsCache {
  struct Key: Hashable, Sendable {
    let root: String
    /// One per session, in practice: the reflog and the working tree are read against it.
    let since: Date
  }

  struct References: Sendable {
    let fingerprint: ReferenceFingerprint?
    let head: RepositoryHead
    let change: BranchChange?
  }

  struct WorkingTree: Sendable {
    let isDirty: Bool
    /// The monitor's reading it was told by, or `nil` for a status of the report's own.
    let observedAt: Date?
    let checkedAt: Date
  }

  /// A few sessions of a few repositories each: past this, the oldest are not worth keeping.
  static let capacity = 256

  private var references: [Key: References] = [:]
  private var workingTrees: [Key: WorkingTree] = [:]

  func references(for key: Key) -> References? { references[key] }

  func workingTree(for key: Key) -> WorkingTree? { workingTrees[key] }

  func remember(_ read: References, for key: Key) {
    if references[key] == nil, references.count >= Self.capacity { references.removeAll() }
    references[key] = read
  }

  func remember(_ tree: WorkingTree, for key: Key) {
    if workingTrees[key] == nil, workingTrees.count >= Self.capacity { workingTrees.removeAll() }
    workingTrees[key] = tree
  }

  func forget(_ key: Key) {
    references[key] = nil
    workingTrees[key] = nil
  }
}

extension WorkingTreeStatus {
  /// Whether a file this status lists was written after `date`, with `stat` only: the rule the
  /// report applies to a status of its own, applied to one the monitor already read.
  ///
  /// `nil` when the list was cut short without an answer: what is beyond it is unknown.
  public func hasChanges(since date: Date, limit: Int = 500) -> Bool? {
    var checked = 0
    for entry in entries {
      guard checked < limit else { return false }
      checked += 1
      let file = (repositoryPath as NSString).appendingPathComponent(entry.path)
      if let modified = (try? FileManager.default.attributesOfItem(atPath: file))?[
        .modificationDate] as? Date, modified > date
      {
        return true
      }
    }
    return isTruncated ? nil : false
  }
}
