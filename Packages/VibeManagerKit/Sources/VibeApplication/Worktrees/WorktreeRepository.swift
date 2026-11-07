import Foundation

/// The repository a worktree belongs to (#525): a session working in one is filed under it, with
/// the other sessions of its project.
public enum WorktreeRepository {
  /// Read on disk: a linked worktree's `.git` is a file, `gitdir: <main>/.git/worktrees/<name>`.
  /// `nil` for any other folder — a clone, a submodule, a plain folder, one that is gone.
  public static func onDisk(of folder: String) -> String? {
    let folder = (folder as NSString).standardizingPath
    let dotGit = (folder as NSString).appendingPathComponent(".git")
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
  /// away from the repository: nothing can be read there. `nil` for any other folder.
  public static func inPath(of folder: String) -> String? {
    // The first one in the path, whichever it is: a worktree made from another worktree still
    // hangs from the clone.
    let markers = ["/.claude/worktrees/", "/.worktrees/"]
      .compactMap { folder.range(of: $0) }
      .sorted { $0.lowerBound < $1.lowerBound }
    for range in markers {
      let repository = String(folder[..<range.lowerBound])
      let name = folder[range.upperBound...].split(separator: "/")
      guard !repository.isEmpty, !name.isEmpty else { continue }
      return repository
    }
    return nil
  }
}
