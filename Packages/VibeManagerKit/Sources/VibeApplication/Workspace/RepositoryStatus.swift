import Foundation
import VibeDomain

/// Where Git keeps a repository's own state, and the state its worktrees share.
///
/// Both matter to whoever watches it: a commit made in a linked worktree touches nothing inside
/// the worktree, only its `git-dir` — which lives under the clone's `git-common-dir`.
public struct GitDirectories: Hashable, Sendable {
  public let gitDirectory: String
  public let commonDirectory: String

  public init(gitDirectory: String, commonDirectory: String) {
    self.gitDirectory = gitDirectory
    self.commonDirectory = commonDirectory
  }
}

/// A repository, read. Implemented over `GitCommandRunner` by `GitStatusReader`.
public protocol RepositoryStatusReading: Sendable {
  /// `git status`, at most `limit` entries kept and every one of them counted.
  func status(atPath path: String, limit: Int) async -> Result<
    WorkingTreeStatus, RepositoryStatusIssue
  >
  func gitDirectories(atPath path: String) async -> Result<GitDirectories, RepositoryStatusIssue>
  /// The files of a folder `git status` reports as one untracked entry, at most `limit` of them
  /// kept and every one counted. Read only when someone unfolds it.
  func untrackedFiles(in directory: String, atPath path: String, limit: Int) async -> Result<
    UntrackedListing, RepositoryStatusIssue
  >
}

/// What an untracked folder holds, as `git status --untracked-files=all` lists it.
public struct UntrackedListing: Hashable, Sendable {
  /// Relative to the repository's root, with its trailing `/`, as Git wrote it.
  public let directory: String
  /// Relative to the repository's root, in Git's order.
  public let paths: [String]
  /// Every file, even past the limit.
  public let totalCount: Int

  public init(directory: String, paths: [String], totalCount: Int) {
    self.directory = directory
    self.paths = paths
    self.totalCount = totalCount
  }

  public var isTruncated: Bool { totalCount > paths.count }
}

/// What the file system says about the folders being watched — never what changed in them, only
/// that something may have.
public enum FileChangeSignal: Hashable, Sendable {
  /// Paths that moved, files or folders, as the system reported them.
  case changed([String])
  /// Events were dropped: everything watched has to be read again.
  case mustRescan
  /// A watched folder was moved or deleted.
  case rootChanged(String)
}

/// Watches folders. Implemented with FSEvents by `FSEventsFileChangeObserver`.
public protocol FileChangeObserving: Sendable {
  /// A stream that watches `paths` until it is no longer iterated.
  func signals(for paths: [String]) -> AsyncStream<FileChangeSignal>
}

/// Where an agent writes the transcript of a session, so that its growth can be watched.
public protocol SessionTranscriptLocating: Sendable {
  func transcriptDirectories(for session: WorkSession) async -> [String]
}

/// Why a repository could not be read. Each case carries its sentence and what to do about it, in
/// the manner of `SessionDraftIssue`: a row shows the three without knowing which it holds.
public enum RepositoryStatusIssue: Error, Hashable, Sendable {
  case missing(path: String)
  case notARepository(path: String)
  case locked(lockPath: String, since: Date)
  case permissionDenied(path: String)
  case unsafeRepository(path: String)
  case gitUnavailable(GitUnavailable)
  case timedOut(after: Duration)
  case failed(summary: String)

  public var message: String {
    switch self {
    case .missing:
      return String(localized: "This repository is no longer where it was.", bundle: .module)
    case .notARepository:
      return String(localized: "This folder is no longer a Git repository.", bundle: .module)
    case .locked(_, let since):
      let minutes = max(1, Int(Date().timeIntervalSince(since) / 60))
      return String(
        localized: "Another Git process has been working in this repository for \(minutes) min.",
        bundle: .module)
    case .permissionDenied:
      return String(
        localized: "macOS does not let Vibe Manager read this repository.", bundle: .module)
    case .unsafeRepository:
      return String(
        localized: "Git refuses to read this repository: it belongs to another user.",
        bundle: .module)
    case .gitUnavailable(let reason):
      return reason.errorDescription ?? String(localized: "Git could not be run.", bundle: .module)
    case .timedOut(let after):
      return String(
        localized: "This repository took more than \(after.components.seconds) s to answer.",
        bundle: .module)
    case .failed(let summary):
      return summary.isEmpty
        ? String(localized: "Git could not read this repository.", bundle: .module) : summary
    }
  }

  public var suggestion: String? {
    switch self {
    case .missing, .notARepository:
      return String(
        localized: """
          Nothing is repaired automatically: reveal the folder, and restart the session where the \
          repository now is.
          """,
        bundle: .module)
    case .locked:
      return String(
        localized:
          "If no Git command is running any more, the lock was left behind and can be removed.",
        bundle: .module)
    case .permissionDenied:
      return String(
        localized: "Give Vibe Manager Full Disk Access in System Settings.", bundle: .module)
    case .unsafeRepository:
      return String(localized: "Mark it as safe if you trust it.", bundle: .module)
    case .gitUnavailable(.commandLineToolsMissing):
      return String(localized: "Install the Command Line Tools.", bundle: .module)
    case .gitUnavailable:
      return String(localized: "Install Git, then read the repositories again.", bundle: .module)
    case .timedOut, .failed:
      return String(localized: "Read the repositories again.", bundle: .module)
    }
  }

  /// A command to copy into a terminal — escaped for the shell, and never run by the application.
  public var copyableCommand: String? {
    switch self {
    case .locked(let lockPath, _):
      return "rm \(ShellWord.quote(lockPath))"
    case .unsafeRepository(let path):
      return "git config --global --add safe.directory \(ShellWord.quote(path))"
    case .gitUnavailable(.commandLineToolsMissing):
      return "xcode-select --install"
    default:
      return nil
    }
  }

  /// Reads a refusal from Git. The runner runs Git in English whatever the user's region, so these
  /// sentences are the same on every Mac.
  public static func classify(errorOutput: String, path: String) -> RepositoryStatusIssue {
    let text = errorOutput.lowercased()
    if text.contains("dubious ownership") {
      return .unsafeRepository(path: path)
    }
    if text.contains("not a git repository") {
      return .notARepository(path: path)
    }
    if text.contains("permission denied") || text.contains("operation not permitted") {
      return .permissionDenied(path: path)
    }
    if text.contains("no such file or directory") || text.contains("cannot change to") {
      return .missing(path: path)
    }
    let firstLine =
      errorOutput
      .split(separator: "\n", omittingEmptySubsequences: true)
      .first
      .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    return .failed(summary: firstLine)
  }
}

/// A word the shell reads back unchanged.
enum ShellWord {
  static func quote(_ word: String) -> String {
    let safe = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+:@%")
    if !word.isEmpty, word.unicodeScalars.allSatisfy({ safe.contains($0) }) {
      return word
    }
    return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
  }
}
