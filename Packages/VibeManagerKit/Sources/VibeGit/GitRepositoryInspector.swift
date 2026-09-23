import Foundation
import VibeApplication

/// Reads what a folder is, with Git's plumbing and nothing that writes.
///
/// `rev-parse` for where the repository and its worktree are, `symbolic-ref` for the branch,
/// `worktree list --porcelain -z` for the other worktrees, `for-each-ref` for the branches,
/// `status --porcelain=v2 -z` for whether anything is uncommitted. `-z` wherever Git offers it,
/// because a file name may contain a newline.
public struct GitRepositoryInspector: RepositoryInspecting {
  private let git: any GitCommandRunner
  private let folders: any WorkingDirectoryProbe

  public init(
    git: any GitCommandRunner = ProcessGitCommandRunner(),
    folders: any WorkingDirectoryProbe = FileManagerWorkingDirectoryProbe()
  ) {
    self.git = git
    self.folders = folders
  }

  public func inspect(path: String) async -> RepositoryInspection {
    let status = await folders.inspect(path: path)
    guard status == .usable else { return .unusable(status) }

    do {
      let location = try await git.run(
        ["rev-parse", "--is-bare-repository", "--path-format=absolute", "--git-common-dir"],
        in: path
      )
      // Not inside a repository at all: a plain folder, which is a perfectly good thing to be.
      guard location.succeeded else { return .plainFolder }
      let lines = location.text.split(separator: "\n").map(String.init)
      guard lines.count >= 2 else { return .plainFolder }
      let commonDirectory = CanonicalPath.of(lines[1])
      if lines[0] == "true" { return .bare(commonDirectory: commonDirectory) }

      let topLevelResult = try await git.run(["rev-parse", "--show-toplevel"], in: path)
      // Inside the `.git` folder itself, or a repository with no working tree configured.
      guard topLevelResult.succeeded, !topLevelResult.text.isEmpty else {
        return .bare(commonDirectory: commonDirectory)
      }
      let topLevel = CanonicalPath.of(topLevelResult.text)
      return .repository(try await facts(topLevel: topLevel, commonDirectory: commonDirectory))
    } catch let problem as GitUnavailable {
      // Without Git, the only thing that can still be told is whether this folder *looks* like a
      // repository. One that does is refused with the remedy; one that does not is a plain folder.
      let marker = (path as NSString).appendingPathComponent(".git")
      return FileManager.default.fileExists(atPath: marker)
        ? .gitUnavailable(problem) : .plainFolder
    } catch {
      return .gitUnavailable(.failedToStart(error.localizedDescription))
    }
  }

  private func facts(topLevel: String, commonDirectory: String) async throws -> GitRepositoryFacts {
    let head = try await git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: topLevel)
    let symbolic = try await git.run(["symbolic-ref", "--quiet", "HEAD"], in: topLevel)
    let worktrees = try await git.run(["worktree", "list", "--porcelain", "-z"], in: topLevel)
    let branches = try await git.run(
      ["for-each-ref", "--format=%(refname)", "refs/heads"], in: topLevel)
    let status = try await git.run(
      ["status", "--porcelain=v2", "-z", "--untracked-files=normal"], in: topLevel)
    let remoteHead = try await git.run(
      ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], in: topLevel)

    var defaultBranch: GitBranchReference?
    if remoteHead.succeeded, !remoteHead.text.isEmpty {
      let reference = remoteHead.text
      let revision = try await git.run(
        ["rev-parse", "--verify", "--quiet", reference], in: topLevel)
      if revision.succeeded {
        let name = reference.replacingOccurrences(of: "refs/remotes/", with: "")
        defaultBranch = GitBranchReference(name: name, revision: revision.text)
      }
    }

    let branchName: String? =
      symbolic.succeeded ? Self.shortBranch(symbolic.text) : nil
    let hasSubmodules = FileManager.default.fileExists(
      atPath: (topLevel as NSString).appendingPathComponent(".gitmodules"))

    return GitRepositoryFacts(
      topLevelPath: topLevel,
      commonDirectory: commonDirectory,
      headRevision: head.succeeded && !head.text.isEmpty ? head.text : nil,
      branchName: branchName,
      isDirty: status.succeeded && !status.output.isEmpty,
      hasSubmodules: hasSubmodules,
      defaultBranch: defaultBranch,
      localBranches: Set(
        branches.text.split(separator: "\n").compactMap { Self.shortBranch(String($0)) }),
      worktrees: worktrees.succeeded ? Self.parseWorktrees(worktrees.output) : []
    )
  }

  static func shortBranch(_ reference: String) -> String? {
    let prefix = "refs/heads/"
    guard reference.hasPrefix(prefix) else { return nil }
    return String(reference.dropFirst(prefix.count))
  }

  /// `worktree list --porcelain -z`: one field per NUL, one record per empty field.
  static func parseWorktrees(_ data: Data) -> [GitWorktreeRecord] {
    let fields = String(decoding: data, as: UTF8.self)
      .split(separator: "\0", omittingEmptySubsequences: false)
      .map(String.init)

    var records: [GitWorktreeRecord] = []
    var current: [String] = []
    func flush() {
      defer { current = [] }
      guard let first = current.first, first.hasPrefix("worktree ") else { return }
      var head: String?
      var branch: String?
      var isBare = false
      var isLocked = false
      var lockReason: String?
      var isPrunable = false
      for field in current.dropFirst() {
        if field.hasPrefix("HEAD ") {
          head = String(field.dropFirst(5))
        } else if field.hasPrefix("branch ") {
          branch = shortBranch(String(field.dropFirst(7)))
        } else if field == "bare" {
          isBare = true
        } else if field == "locked" || field.hasPrefix("locked ") {
          isLocked = true
          let reason = field.dropFirst(6).trimmingCharacters(in: .whitespaces)
          lockReason = reason.isEmpty ? nil : reason
        } else if field == "prunable" || field.hasPrefix("prunable ") {
          isPrunable = true
        }
      }
      records.append(
        GitWorktreeRecord(
          path: CanonicalPath.of(String(first.dropFirst(9))),
          headRevision: head,
          branchName: branch,
          isBare: isBare,
          isLocked: isLocked,
          lockReason: lockReason,
          isPrunable: isPrunable
        )
      )
    }
    for field in fields {
      if field.isEmpty {
        flush()
      } else {
        current.append(field)
      }
    }
    flush()
    return records
  }
}
