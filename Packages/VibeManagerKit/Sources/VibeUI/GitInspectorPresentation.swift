import Foundation
import VibeApplication
import VibeDomain

/// The four lists a repository's changes fall into, in the order they are shown: what blocks the
/// agent first, then what `git status` says, in its order.
enum ChangeColumn: Int, CaseIterable, Hashable, Sendable, Comparable {
  case conflicts
  case staged
  case unstaged
  case untracked

  var title: String {
    switch self {
    case .conflicts: return "Conflicts"
    case .staged: return "Staged"
    case .unstaged: return "Unstaged"
    case .untracked: return "Untracked"
    }
  }

  static func < (lhs: ChangeColumn, rhs: ChangeColumn) -> Bool { lhs.rawValue < rhs.rawValue }

  /// The lists an entry appears in: two for a file staged and changed again.
  static func of(_ entry: WorkingTreeEntry) -> [ChangeColumn] {
    switch entry.kind {
    case .conflicted: return [.conflicts]
    case .untracked, .untrackedDirectory: return [.untracked]
    case .tracked(let staged, let unstaged), .submodule(let staged, let unstaged, _):
      var columns: [ChangeColumn] = []
      if staged != nil { columns.append(.staged) }
      if unstaged != nil { columns.append(.unstaged) }
      return columns
    }
  }
}

/// A section of one repository's changes.
struct GitSectionID: Hashable, Sendable {
  let repositoryPath: String
  let column: ChangeColumn
}

/// What a row designates, and nothing else: no index, no count. It is what keeps a selection, an
/// expansion and a scroll position through every state the monitor publishes.
struct GitInspectorRowID: Hashable, Sendable {
  /// `RepositoryBranchReport.path`.
  let repositoryPath: String
  let column: ChangeColumn
  /// `WorkingTreeEntry.path`, as Git wrote it.
  let path: String
  /// A file of an unfolded untracked folder, relative to the repository's root.
  let child: String?

  init(repositoryPath: String, column: ChangeColumn, path: String, child: String? = nil) {
    self.repositoryPath = repositoryPath
    self.column = column
    self.path = path
    self.child = child
  }

  var section: GitSectionID { GitSectionID(repositoryPath: repositoryPath, column: column) }

  /// The file on disk this row stands for, relative to the repository's root.
  var relativePath: String { child ?? path }
}

/// How a status letter is coloured. The letter carries the meaning; the colour only repeats it.
enum ChangeTone: Hashable, Sendable {
  case added
  case modified
  case deleted
  case renamed
  case conflicted
  case untracked
}

/// One row of the list, ready to be drawn.
struct FileRow: Equatable, Identifiable, Sendable {
  let id: GitInspectorRowID
  /// `M`, `A`, `D`, `R`, `C`, `T`, `UU`, `?`…
  let letter: String
  let tone: ChangeTone
  /// The last component, in NFC. A folder keeps its trailing `/`.
  let name: String
  /// The parent folder, relative to the root, in NFC; `nil` at the root.
  let directory: String?
  /// For a rename or a copy.
  let renamedFrom: String?
  /// "renamed, 92 % similar", "both modified", "commit changed"…
  let change: String
  let isAttributed: Bool
  /// False for a file deleted from the working tree: there is nothing to open, only a folder to
  /// reveal.
  let isOnDisk: Bool
  let isDirectory: Bool
  let isSubmodule: Bool
  let accessibilityLabel: String

  /// The row's full path, relative to the root, for its tooltip.
  var help: String {
    var text = id.relativePath.precomposedStringWithCanonicalMapping
    if let renamedFrom { text += " ← " + renamedFrom }
    text += " — " + change
    if !isAttributed { text += "\n" + FileRow.unattributedHelp }
    return text
  }

  static let unattributedHelp =
    "Not in this session's transcript: changed by a shell command, another session, or you."
}

struct FileSection: Equatable, Identifiable, Sendable {
  let id: GitSectionID
  let rows: [FileRow]

  var column: ChangeColumn { id.column }
}

/// What the header of a repository says of its branch.
enum BranchLine: Equatable, Sendable {
  case named(String)
  case detached(revision: String?)
  /// Before the first commit, on the branch it will be made on.
  case unborn(String?)
  case unknown

  var text: String {
    switch self {
    case .named(let name): return name
    case .detached(let revision?): return "detached at \(revision.prefix(7))"
    case .detached(nil): return "detached HEAD"
    case .unborn(let name?): return "\(name), no commits yet"
    case .unborn(nil): return "no commits yet"
    case .unknown: return "No branch"
    }
  }
}

/// A failure, laid out: what happened, what to do, and the one button that does it.
struct IssueBanner: Equatable, Sendable {
  enum Action: Equatable, Sendable {
    case refresh
    case revealParent(String)
    case openPrivacySettings
  }

  let issue: RepositoryStatusIssue
  let message: String
  let suggestion: String?
  let command: String?
  let action: Action
  /// When the failure started; the list below it is what was true before.
  let since: Date

  init(issue: RepositoryStatusIssue, since: Date, repositoryPath: String) {
    self.issue = issue
    message = issue.message
    suggestion = issue.suggestion
    command = issue.copyableCommand
    self.since = since
    switch issue {
    case .missing, .notARepository:
      action = .revealParent((repositoryPath as NSString).deletingLastPathComponent)
    case .permissionDenied:
      action = .openPrivacySettings
    default:
      action = .refresh
    }
  }
}

/// One repository of the session, as its group in the inspector shows it. Pure: built from the
/// branch report's line and the monitor's state, and tested without a view.
struct RepositoryGroupPresentation: Equatable, Identifiable, Sendable {
  let repositoryPath: String
  let title: String
  /// "worktree oauth", for a worktree the agent made itself.
  let worktree: String?
  let branch: BranchLine
  /// "2 ahead, 1 behind origin/main", only with an upstream and a distance.
  let distance: String?
  /// "↑2 ↓1", the same distance in the header's own short form.
  let arrows: String?
  let distanceHelp: String
  let pills: [Pill]
  let operation: String?
  /// The counts in words, from #13's presentation.
  let summary: String
  let details: [String]
  let sections: [FileSection]
  let changeCount: Int
  let isTruncated: Bool
  let isLoading: Bool
  let isUnreadable: Bool
  let banner: IssueBanner?
  /// When the list shown is not live: the moment it was true.
  let asOf: Date?
  let issue: RepositoryStatusIssue?

  struct Pill: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case new, advanced, rewritten, unreadable }
    let label: String
    let tone: Tone
  }

  var id: String { repositoryPath }
  var hasChanges: Bool { changeCount > 0 }

  /// Unfolded when there is something to see: changes, or a failure to read about.
  var isExpandedByDefault: Bool { hasChanges || banner != nil || isUnreadable }

  var accessibilityLabel: String {
    var parts = ["Repository \(title)"]
    if let worktree { parts.append(worktree) }
    parts.append("branch \(branch.text)")
    if let distance { parts.append(distance) }
    if let operation { parts.append(operation) }
    parts.append(summary)
    return parts.joined(separator: ", ")
  }

  init(
    report: RepositoryBranchReport,
    state: RepositoryStatusState?,
    sessionNames: [SessionID: String] = [:]
  ) {
    repositoryPath = report.path
    let parts = report.name.components(separatedBy: " · worktree ")
    title = parts[0]
    worktree = parts.count > 1 ? "worktree \(parts[1])" : nil
    isUnreadable = report.isUnreadable

    let status = state?.lastValid
    if let branch = status?.branch {
      if branch.headRevision == nil {
        self.branch = .unborn(branch.branchName)
      } else if let name = branch.branchName {
        self.branch = .named(name)
      } else {
        self.branch = .detached(revision: branch.headRevision)
      }
    } else if let name = report.checkedOutBranch, !report.isUnreadable {
      branch = .named(name)
    } else {
      branch = .unknown
    }

    if let branch = status?.branch, let upstream = branch.upstream {
      let ahead = branch.ahead ?? 0
      let behind = branch.behind ?? 0
      var parts: [String] = []
      if ahead > 0 { parts.append("\(ahead) ahead") }
      if behind > 0 { parts.append("\(behind) behind") }
      distance = parts.isEmpty ? nil : parts.joined(separator: ", ") + " " + upstream
      var arrows: [String] = []
      if ahead > 0 { arrows.append("↑\(ahead)") }
      if behind > 0 { arrows.append("↓\(behind)") }
      self.arrows = arrows.isEmpty ? nil : arrows.joined(separator: " ")
      distanceHelp = "Compared with \(upstream), as last fetched: nothing is fetched here."
    } else {
      distance = nil
      arrows = nil
      distanceHelp = "No upstream branch."
    }

    var pills: [Pill] = []
    if report.isUnreadable {
      pills.append(Pill(label: "unreadable", tone: .unreadable))
    } else if let change = report.change {
      if change.kind == .created { pills.append(Pill(label: "new", tone: .new)) }
      switch change.kind {
      case .created, .advanced:
        if let count = change.commitCount, count > 0 {
          pills.append(Pill(label: "+\(count)", tone: .advanced))
        }
      case .rewritten:
        pills.append(Pill(label: "rewritten", tone: .rewritten))
      }
    }
    self.pills = pills

    operation = status?.operation.map(RepositoryStatusPresentation.sentence(for:))

    if let state {
      let presentation = RepositoryStatusPresentation(state: state, sessionNames: sessionNames)
      // The counts on one line, what the transcript does not account for on its own: joined,
      // they no longer fit the column and the half that matters most is the one cut.
      var details: [String] = []
      if let status {
        summary = RepositoryStatusPresentation.summary(of: status, unattributed: 0)
        let unattributed = state.unattributedCount
        if unattributed > 0, !status.isTruncated {
          details.append(
            unattributed == state.entries.count
              ? "None in this session's transcript"
              : "\(unattributed) not in this session's transcript")
        }
      } else {
        summary = presentation.summary
      }
      // The distance and the operation have their own place in the header.
      self.details = details + presentation.details.filter { $0.hasPrefix("Shared with") }
    } else {
      summary = report.isUnreadable ? "This repository could not be read." : "Not read yet"
      details = []
    }

    sections = state.map { Self.sections(of: $0.entries, in: report.path) } ?? []
    changeCount = state?.entries.count ?? 0
    isTruncated = status?.isTruncated ?? false
    isLoading = state == nil || (state?.lastValid == nil && state?.phase == .refreshing)

    switch state?.phase {
    case .failed(let issue, let since):
      banner = IssueBanner(issue: issue, since: since, repositoryPath: report.path)
      self.issue = issue
      asOf = status?.observedAt
    case .unobserved:
      banner = nil
      issue = nil
      asOf = status?.observedAt
    default:
      banner = nil
      issue = nil
      asOf = nil
    }
  }

  /// Git's entries, split into their lists. An entry indexed and changed again since (`MM`) is in
  /// both: what the commit will hold is not what is on disk.
  static func sections(of entries: [AttributedEntry], in repositoryPath: String) -> [FileSection] {
    var rows: [ChangeColumn: [FileRow]] = [:]
    for attributed in entries {
      let entry = attributed.entry
      switch entry.kind {
      case .conflicted(let kind):
        rows[.conflicts, default: []].append(
          FileRow(
            repositoryPath: repositoryPath, column: .conflicts, entry: attributed,
            letter: kind.code, tone: .conflicted, change: kind.sentence,
            isOnDisk: kind.leavesFileOnDisk))
      case .untracked, .untrackedDirectory:
        rows[.untracked, default: []].append(
          FileRow(
            repositoryPath: repositoryPath, column: .untracked, entry: attributed, letter: "?",
            tone: .untracked,
            change: entry.kind == .untrackedDirectory ? "untracked folder" : "untracked",
            isOnDisk: true))
      case .tracked(let staged, let unstaged):
        if let staged {
          rows[.staged, default: []].append(
            FileRow(
              repositoryPath: repositoryPath, column: .staged, entry: attributed, change: staged,
              isOnDisk: unstaged != .deleted && (staged != .deleted || unstaged != nil)))
        }
        if let unstaged {
          rows[.unstaged, default: []].append(
            FileRow(
              repositoryPath: repositoryPath, column: .unstaged, entry: attributed,
              change: unstaged, isOnDisk: unstaged != .deleted))
        }
      case .submodule(let staged, let unstaged, let submodule):
        if let staged {
          rows[.staged, default: []].append(
            FileRow(
              repositoryPath: repositoryPath, column: .staged, entry: attributed, change: staged,
              isOnDisk: staged != .deleted, submodule: submodule))
        }
        if let unstaged {
          rows[.unstaged, default: []].append(
            FileRow(
              repositoryPath: repositoryPath, column: .unstaged, entry: attributed,
              change: unstaged, isOnDisk: unstaged != .deleted, submodule: submodule))
        }
      }
    }
    return ChangeColumn.allCases.compactMap { column in
      guard let rows = rows[column], !rows.isEmpty else { return nil }
      return FileSection(
        id: GitSectionID(repositoryPath: repositoryPath, column: column), rows: rows)
    }
  }
}

extension FileRow {
  /// A tracked change, in the staged or the unstaged column.
  fileprivate init(
    repositoryPath: String, column: ChangeColumn, entry: AttributedEntry, change: FileChange,
    isOnDisk: Bool, submodule: SubmoduleChange? = nil
  ) {
    var renamedFrom: String?
    var sentence: String
    let letter: String
    let tone: ChangeTone
    switch change {
    case .added:
      (letter, tone, sentence) = ("A", .added, "added")
    case .modified:
      (letter, tone, sentence) = ("M", .modified, "modified")
    case .deleted:
      (letter, tone, sentence) = ("D", .deleted, "deleted")
    case .typeChanged:
      (letter, tone, sentence) = ("T", .modified, "type changed")
    case .renamed(let from, let similarity):
      (letter, tone, sentence) = ("R", .renamed, "renamed, \(similarity) % similar")
      renamedFrom = from.precomposedStringWithCanonicalMapping
    case .copied(let from, let similarity):
      (letter, tone, sentence) = ("C", .added, "copied, \(similarity) % similar")
      renamedFrom = from.precomposedStringWithCanonicalMapping
    }
    if let submodule {
      var parts: [String] = []
      if submodule.contains(.commitChanged) { parts.append("commit changed") }
      if submodule.contains(.trackedChanges) { parts.append("modified content") }
      if submodule.contains(.untrackedChanges) { parts.append("untracked content") }
      sentence = (["submodule"] + (parts.isEmpty ? [sentence] : parts)).joined(separator: ", ")
    }
    self.init(
      repositoryPath: repositoryPath, column: column, entry: entry, letter: letter, tone: tone,
      change: sentence, isOnDisk: isOnDisk, renamedFrom: renamedFrom,
      isSubmodule: submodule != nil)
  }

  fileprivate init(
    repositoryPath: String, column: ChangeColumn, entry: AttributedEntry, letter: String,
    tone: ChangeTone, change: String, isOnDisk: Bool, renamedFrom: String? = nil,
    isSubmodule: Bool = false
  ) {
    let path = entry.entry.path
    let isDirectory = entry.entry.kind == .untrackedDirectory
    let (name, directory) = Self.split(path)
    self.init(
      id: GitInspectorRowID(repositoryPath: repositoryPath, column: column, path: path),
      letter: letter,
      tone: tone,
      name: name,
      directory: directory,
      renamedFrom: renamedFrom,
      change: change,
      isAttributed: entry.touchedByAgent,
      isOnDisk: isOnDisk,
      isDirectory: isDirectory,
      isSubmodule: isSubmodule,
      accessibilityLabel: Self.label(
        name: name, directory: directory, column: column, change: change,
        renamedFrom: renamedFrom, isAttributed: entry.touchedByAgent)
    )
  }

  /// A file of an unfolded untracked folder.
  init(repositoryPath: String, directory entry: String, child: String) {
    let (name, directory) = Self.split(child)
    self.init(
      id: GitInspectorRowID(
        repositoryPath: repositoryPath, column: .untracked, path: entry, child: child),
      letter: "?",
      tone: .untracked,
      name: name,
      directory: directory,
      renamedFrom: nil,
      change: "untracked",
      // Attribution is the folder's: the transcript is not asked file by file.
      isAttributed: true,
      isOnDisk: true,
      isDirectory: child.hasSuffix("/"),
      isSubmodule: false,
      accessibilityLabel: Self.label(
        name: name, directory: directory, column: .untracked, change: "untracked",
        renamedFrom: nil, isAttributed: true)
    )
  }

  /// The name and its folder, for display: in NFC, so that a name macOS wrote decomposed reads
  /// the same as one typed. The key keeps Git's own spelling.
  static func split(_ path: String) -> (name: String, directory: String?) {
    let display = path.precomposedStringWithCanonicalMapping
    let isFolder = display.hasSuffix("/")
    let trimmed = isFolder ? String(display.dropLast()) : display
    guard let slash = trimmed.lastIndex(of: "/") else {
      return (trimmed + (isFolder ? "/" : ""), nil)
    }
    let name = String(trimmed[trimmed.index(after: slash)...]) + (isFolder ? "/" : "")
    return (name, String(trimmed[..<slash]))
  }

  private static func label(
    name: String, directory: String?, column: ChangeColumn, change: String,
    renamedFrom: String?, isAttributed: Bool
  ) -> String {
    var parts = [name]
    if let directory { parts.append("in \(directory)") }
    if let renamedFrom { parts.append("from \(renamedFrom)") }
    parts.append(
      column == .untracked || column == .conflicts
        ? change : "\(column.title.lowercased()): \(change)")
    if !isAttributed { parts.append("not in this session's transcript") }
    return parts.joined(separator: ", ")
  }
}

extension ConflictKind {
  /// The two letters `git status --short` prints.
  var code: String {
    switch self {
    case .bothModified: return "UU"
    case .bothAdded: return "AA"
    case .bothDeleted: return "DD"
    case .addedByUs: return "AU"
    case .addedByThem: return "UA"
    case .deletedByUs: return "DU"
    case .deletedByThem: return "UD"
    }
  }

  var sentence: String {
    switch self {
    case .bothModified: return "conflict: both modified"
    case .bothAdded: return "conflict: both added"
    case .bothDeleted: return "conflict: both deleted"
    case .addedByUs: return "conflict: added by us"
    case .addedByThem: return "conflict: added by them"
    case .deletedByUs: return "conflict: deleted by us"
    case .deletedByThem: return "conflict: deleted by them"
    }
  }

  var leavesFileOnDisk: Bool { self != .bothDeleted }
}

/// The inspector's Git pane, as a whole: its groups, and what is said above them.
struct GitPanePresentation: Equatable, Sendable {
  let groups: [RepositoryGroupPresentation]
  /// Attached folders no repository of the report covers — a folder of repositories, typically.
  let plainFolders: [String]
  /// "Nothing to commit in 3 repositories", when every one of them is clean.
  let allClean: String?
  /// The same failure everywhere — Git missing — said once rather than once per repository.
  let sharedIssue: IssueBanner?

  init(groups: [RepositoryGroupPresentation], plainFolders: [String]) {
    self.groups = groups
    self.plainFolders = plainFolders
    let read = groups.filter { !$0.isLoading && $0.banner == nil && !$0.isUnreadable }
    allClean =
      groups.count > 1 && read.count == groups.count && groups.allSatisfy { !$0.hasChanges }
      ? "Nothing to commit in \(groups.count) repositories" : nil

    let issues = groups.compactMap(\.issue)
    if groups.count > 1, issues.count == groups.count,
      case .gitUnavailable = issues[0], Set(issues).count == 1,
      let first = groups.first?.banner
    {
      sharedIssue = first
    } else {
      sharedIssue = nil
    }
  }

  /// The attached folders none of the repositories covers. Asks the disk: to be called once per
  /// report, not at every redraw.
  static func plainFolders(_ folders: [String], roots: [String]) -> [String] {
    let roots = roots.map(CanonicalPath.of)
    return folders.filter { folder in
      let canonical = CanonicalPath.of(folder)
      return !roots.contains { canonical == $0 || canonical.hasPrefix($0 + "/") }
    }
  }
}
