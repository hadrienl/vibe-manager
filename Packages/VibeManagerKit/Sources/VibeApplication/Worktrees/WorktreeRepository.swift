import Foundation

/// The repository a worktree belongs to (#525): a session working in one is filed under it, with
/// the other sessions of its project.
public enum WorktreeRepository {
  /// Read on disk: a linked worktree's `.git` is a file, `gitdir: <main>/.git/worktrees/<name>`.
  /// A folder inside a worktree belongs to it too: the nearest `.git` above it answers, one look
  /// per folder on the way, never above the home folder. `nil` for any other folder — a clone, a
  /// submodule, a plain folder, one that is gone.
  public static func onDisk(of folder: String) -> String? {
    onDisk(of: folder, home: NSHomeDirectory())
  }

  static func onDisk(of folder: String, home: String) -> String? {
    let home = (home as NSString).standardizingPath
    var folder = (folder as NSString).standardizingPath
    while folder != "/", folder != home, !folder.isEmpty {
      let dotGit = (folder as NSString).appendingPathComponent(".git")
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
        // The first `.git` met decides: a clone's folder, or a worktree's file.
        return isDirectory.boolValue ? nil : repository(readIn: dotGit, of: folder)
      }
      folder = (folder as NSString).deletingLastPathComponent
    }
    return nil
  }

  private static func repository(readIn dotGit: String, of folder: String) -> String? {
    guard let content = try? String(contentsOfFile: dotGit, encoding: .utf8),
      content.hasPrefix("gitdir:")
    else { return nil }
    var gitDirectory = content.dropFirst("gitdir:".count)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // `worktree.useRelativePaths` writes it relative to the worktree.
    if !gitDirectory.hasPrefix("/") {
      gitDirectory = (folder as NSString).appendingPathComponent(gitDirectory)
    }
    gitDirectory = (gitDirectory as NSString).standardizingPath
    guard let range = gitDirectory.range(of: "/.git/worktrees/", options: .backwards) else {
      return nil
    }
    let repository = String(gitDirectory[..<range.lowerBound])
    return repository.isEmpty ? nil : repository
  }

  /// Read in the path alone, for a worktree that is gone: where agents make theirs inside the
  /// repository, `.claude/worktrees` and `.worktrees`. Codex keeps its own under its home folder,
  /// away from the repository: nothing can be read there. Nor in `~/.worktrees`, where worktrees
  /// of every repository are kept: the home folder is nobody's repository. `nil` for any other
  /// folder.
  public static func inPath(of folder: String) -> String? {
    inPath(of: folder, home: NSHomeDirectory())
  }

  static func inPath(of folder: String, home: String) -> String? {
    let home = (home as NSString).standardizingPath
    for marker in ["/.claude/worktrees/", "/.worktrees/"] {
      // The first one: a worktree made from another worktree still hangs from the clone.
      guard let range = folder.range(of: marker) else { continue }
      let repository = String(folder[..<range.lowerBound])
      let name = folder[range.upperBound...].split(separator: "/")
      guard !repository.isEmpty, !name.isEmpty,
        (repository as NSString).standardizingPath != home
      else { continue }
      return repository
    }
    return nil
  }
}
