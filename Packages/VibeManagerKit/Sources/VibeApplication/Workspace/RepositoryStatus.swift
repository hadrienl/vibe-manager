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
      return "This repository is no longer where it was."
    case .notARepository:
      return "This folder is no longer a Git repository."
    case .locked(_, let since):
      let minutes = max(1, Int(Date().timeIntervalSince(since) / 60))
      return
        "Another Git process has been working in this repository for \(minutes) min."
    case .permissionDenied:
      return "macOS does not let Vibe Manager read this repository."
    case .unsafeRepository:
      return "Git refuses to read this repository: it belongs to another user."
    case .gitUnavailable(let reason):
      return reason.errorDescription ?? "Git could not be run."
    case .timedOut(let after):
      return "This repository took more than \(after.components.seconds) s to answer."
    case .failed(let summary):
      return summary.isEmpty ? "Git could not read this repository." : summary
    }
  }

  public var suggestion: String? {
    switch self {
    case .missing, .notARepository:
      return "Nothing is repaired automatically: reveal the folder, and restart the session "
        + "where the repository now is."
    case .locked:
      return "If no Git command is running any more, the lock was left behind and can be removed."
    case .permissionDenied:
      return "Give Vibe Manager Full Disk Access in System Settings."
    case .unsafeRepository:
      return "Mark it as safe if you trust it."
    case .gitUnavailable(.commandLineToolsMissing):
      return "Install the Command Line Tools."
    case .gitUnavailable:
      return "Install Git, then read the repositories again."
    case .timedOut, .failed:
      return "Read the repositories again."
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
