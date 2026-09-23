import Foundation
import VibeDomain

/// A gesture a conflict proposes. Offered, never carried out on its own.
public enum RepositoryResolution: Hashable, Sendable, Identifiable {
  case keepAsPlainFolder
  case chooseAnotherFolder
  /// Put the worktree on the session's branch, which already exists and is checked out nowhere.
  case useExistingBranch
  /// Work in the worktree the session's branch is already checked out in.
  case adoptWorktree(path: String)
  case changeSlug(suggestion: String)
  case chooseAnotherSubfolder(suggestion: String)
  case switchToWorktree
  case createBranchInPlace
  case remove

  public var id: String {
    switch self {
    case .keepAsPlainFolder: return "keepAsPlainFolder"
    case .chooseAnotherFolder: return "chooseAnotherFolder"
    case .useExistingBranch: return "useExistingBranch"
    case .adoptWorktree(let path): return "adoptWorktree|\(path)"
    case .changeSlug(let suggestion): return "changeSlug|\(suggestion)"
    case .chooseAnotherSubfolder(let suggestion): return "chooseAnotherSubfolder|\(suggestion)"
    case .switchToWorktree: return "switchToWorktree"
    case .createBranchInPlace: return "createBranchInPlace"
    case .remove: return "remove"
    }
  }

  public var title: String {
    switch self {
    case .keepAsPlainFolder: return "Keep it as a plain folder"
    case .chooseAnotherFolder: return "Choose another folder"
    case .useExistingBranch: return "Use the existing branch"
    case .adoptWorktree: return "Work in that worktree"
    case .changeSlug(let suggestion): return "Use \(suggestion)"
    case .chooseAnotherSubfolder(let suggestion): return "Use the folder \(suggestion)"
    case .switchToWorktree: return "Use a worktree instead"
    case .createBranchInPlace: return "Create the session branch here"
    case .remove: return "Remove it"
    }
  }
}

/// One thing found about a repository before anything is written, and the ways out of it.
///
/// A sentence and a remedy, like `SessionDraftIssue` and `AgentLaunchError`: the sheet, the
/// inspector and the restart banner all render it with the same view. A command, when there is
/// one, is text to copy — the application never runs it.
public struct RepositoryAttachmentIssue: Hashable, Sendable, Identifiable {
  public enum Kind: String, Hashable, Sendable {
    case notARepository
    case folderUnusable
    case gitUnavailable
    case bare
    case noCommit
    case duplicate
    case branchExists
    case branchCheckedOut
    case pathOccupied
    case staleWorktree
    case lockedWorktree
    case dirty
    case detachedHead
    case submodules
    case defaultBranchUnknown
    case invalidSubfolder
    case otherBranchCheckedOut
    case worktreeMissing
    case cloneMissing
    case preparationFailed
    case cancelled
  }

  public enum Severity: Int, Hashable, Sendable, Comparable {
    /// Something worth knowing, which changes nothing.
    case notice
    /// Something the user should read before confirming.
    case warning
    /// The repository cannot be prepared as planned. Only this repository.
    case blocking

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  public let kind: Kind
  public let severity: Severity
  public let message: String
  public let remedy: String
  public let command: String?
  public let resolutions: [RepositoryResolution]

  public init(
    kind: Kind,
    severity: Severity,
    message: String,
    remedy: String,
    command: String? = nil,
    resolutions: [RepositoryResolution] = []
  ) {
    self.kind = kind
    self.severity = severity
    self.message = message
    self.remedy = remedy
    self.command = command
    self.resolutions = resolutions
  }

  public var id: String { "\(kind.rawValue)|\(message)" }

  public var isBlocking: Bool { severity == .blocking }

  public var failure: RepositoryPreparationFailure {
    RepositoryPreparationFailure(message: message, remedy: remedy)
  }
}

extension RepositoryAttachmentIssue {
  static func folderUnusable(_ status: WorkingDirectoryStatus) -> RepositoryAttachmentIssue {
    let draft: SessionDraftIssue
    switch status {
    case .missing: draft = .workingDirectoryNotFound
    case .notADirectory: draft = .workingDirectoryNotADirectory
    case .unreadable, .usable: draft = .workingDirectoryUnreadable
    }
    return RepositoryAttachmentIssue(
      kind: .folderUnusable,
      severity: .blocking,
      message: draft.message,
      remedy: draft.remedy,
      resolutions: [.chooseAnotherFolder, .remove]
    )
  }

  static let notAbsolute = RepositoryAttachmentIssue(
    kind: .folderUnusable,
    severity: .blocking,
    message: SessionDraftIssue.workingDirectoryNotAbsolute.message,
    remedy: SessionDraftIssue.workingDirectoryNotAbsolute.remedy,
    resolutions: [.chooseAnotherFolder, .remove]
  )

  static let notARepository = RepositoryAttachmentIssue(
    kind: .notARepository,
    severity: .notice,
    message:
      "This folder is not a Git repository, so it is attached as it is — no branch, no worktree.",
    remedy: "Keep it that way, or choose the repository you meant.",
    resolutions: [.keepAsPlainFolder, .chooseAnotherFolder]
  )

  static func gitUnavailable(_ problem: GitUnavailable) -> RepositoryAttachmentIssue {
    RepositoryAttachmentIssue(
      kind: .gitUnavailable,
      severity: .blocking,
      message: problem.errorDescription ?? "Git cannot run.",
      remedy: problem.recoverySuggestion ?? "Install Git, then try again.",
      command: problem.command,
      resolutions: [.remove]
    )
  }

  static let bare = RepositoryAttachmentIssue(
    kind: .bare,
    severity: .blocking,
    message: "This is a bare repository: it has no files to work in.",
    remedy: "Choose a working clone of it instead.",
    resolutions: [.chooseAnotherFolder, .remove]
  )

  static let noCommit = RepositoryAttachmentIssue(
    kind: .noCommit,
    severity: .blocking,
    message: "This repository has no commit yet, so a worktree has nothing to start from.",
    remedy: "Make a first commit, or attach it in place.",
    resolutions: [.remove]
  )

  static let duplicate = RepositoryAttachmentIssue(
    kind: .duplicate,
    severity: .blocking,
    message: "This repository is already attached to the session, through another folder.",
    remedy: "Remove it: one repository has one place in a session, and nothing is merged silently.",
    resolutions: [.remove]
  )

  static func branchExists(_ branch: String, suggestion: SessionSlug) -> RepositoryAttachmentIssue {
    RepositoryAttachmentIssue(
      kind: .branchExists,
      severity: .blocking,
      message: "The branch \(branch) already exists here, and is checked out nowhere.",
      remedy:
        "Put the worktree on it — the usual case of a session picked up again — or change the name.",
      resolutions: [.useExistingBranch, .changeSlug(suggestion: suggestion.rawValue)]
    )
  }

  static func branchExistsInPlace(_ branch: String, suggestion: SessionSlug)
    -> RepositoryAttachmentIssue
  {
    RepositoryAttachmentIssue(
      kind: .branchExists,
      severity: .blocking,
      message: "The branch \(branch) already exists here, so it cannot be created in the clone.",
      remedy: "Use a worktree, which can be put on it, or change the name.",
      resolutions: [.switchToWorktree, .changeSlug(suggestion: suggestion.rawValue)]
    )
  }

  static func branchCheckedOut(
    _ branch: String,
    at path: String,
    suggestion: SessionSlug
  ) -> RepositoryAttachmentIssue {
    RepositoryAttachmentIssue(
      kind: .branchCheckedOut,
      severity: .blocking,
      message:
        "The branch \(branch) is already checked out in \(path), and Git allows one worktree per branch.",
      remedy: "Work in that worktree, or change the name.",
      resolutions: [.adoptWorktree(path: path), .changeSlug(suggestion: suggestion.rawValue)]
    )
  }

  static func pathOccupied(
    _ path: String,
    slugSuggestion: SessionSlug,
    subfolderSuggestion: String
  ) -> RepositoryAttachmentIssue {
    RepositoryAttachmentIssue(
      kind: .pathOccupied,
      severity: .blocking,
      message: "Something already exists at \(path), and it is not a worktree of this repository.",
      remedy: "Change the name, or put this repository in another folder.",
      resolutions: [
        .changeSlug(suggestion: slugSuggestion.rawValue),
        .chooseAnotherSubfolder(suggestion: subfolderSuggestion),
      ]
    )
  }

  static func staleWorktree(
    _ record: GitWorktreeRecord,
    repositoryPath: String,
    suggestion: SessionSlug
  ) -> RepositoryAttachmentIssue {
    RepositoryAttachmentIssue(
      kind: .staleWorktree,
      severity: .blocking,
      message:
        "Git still has a worktree on record at \(record.path), whose folder has disappeared.",
      remedy:
        "Run the command below if that worktree is really gone — Vibe Manager does not run it for you.",
      command: ShellQuoting.command(["git", "-C", repositoryPath, "worktree", "prune"]),
      resolutions: [.changeSlug(suggestion: suggestion.rawValue)]
    )
  }

  static func lockedWorktree(
    _ record: GitWorktreeRecord,
    repositoryPath: String,
    suggestion: SessionSlug
  ) -> RepositoryAttachmentIssue {
    let reason = record.lockReason.map { " (“\($0)”)" } ?? ""
    return RepositoryAttachmentIssue(
      kind: .lockedWorktree,
      severity: .blocking,
      message: "The worktree at \(record.path) is locked\(reason).",
      remedy: "Unlock it with the command below if the reason no longer holds.",
      command: ShellQuoting.command([
        "git", "-C", repositoryPath, "worktree", "unlock", record.path,
      ]),
      resolutions: [.changeSlug(suggestion: suggestion.rawValue)]
    )
  }

  static let dirtyInWorktree = RepositoryAttachmentIssue(
    kind: .dirty,
    severity: .notice,
    message:
      "This clone has uncommitted changes. They stay in the clone: the worktree starts from the last commit.",
    remedy: "Commit or stash them first if the session needs them."
  )

  static let dirtyInPlace = RepositoryAttachmentIssue(
    kind: .dirty,
    severity: .warning,
    message: "This clone has uncommitted changes, and the agent will work on top of them.",
    remedy: "Use a worktree instead to start from a clean copy.",
    resolutions: [.switchToWorktree]
  )

  static let detachedInPlace = RepositoryAttachmentIssue(
    kind: .detachedHead,
    severity: .blocking,
    message: "This clone has a detached HEAD, so working in place has no branch to name.",
    remedy: "Create the session branch here, or use a worktree.",
    resolutions: [.createBranchInPlace, .switchToWorktree]
  )

  static func submodules(worktreePath: String) -> RepositoryAttachmentIssue {
    RepositoryAttachmentIssue(
      kind: .submodules,
      severity: .warning,
      message: "This repository has submodules, and a new worktree does not initialise them.",
      remedy: "Initialise them with the command below if the session needs them.",
      command: ShellQuoting.command([
        "git", "-C", worktreePath, "submodule", "update", "--init", "--recursive",
      ])
    )
  }

  static let defaultBranchUnknown = RepositoryAttachmentIssue(
    kind: .defaultBranchUnknown,
    severity: .warning,
    message: "No remote names a default branch here, so the worktree starts from HEAD instead.",
    remedy: "Choose HEAD as the base to make it explicit."
  )

  static let invalidSubfolder = RepositoryAttachmentIssue(
    kind: .invalidSubfolder,
    severity: .blocking,
    message: "This folder name cannot hold a worktree.",
    remedy: "Use a single folder name, without a slash, that does not start with a dot."
  )

  static func preparationFailed(_ reason: String) -> RepositoryAttachmentIssue {
    RepositoryAttachmentIssue(
      kind: .preparationFailed,
      severity: .blocking,
      message: "Git refused to prepare this repository: \(reason)",
      remedy: "Fix what Git reports, then recreate the worktree from the inspector."
    )
  }

  static let cancelled = RepositoryAttachmentIssue(
    kind: .cancelled,
    severity: .blocking,
    message: "Preparing this repository was cancelled before it started.",
    remedy: "Recreate the worktree from the inspector."
  )
}
