import Foundation
import VibeApplication
import VibeDomain

/// Reads a repository's branches for the session report, with plumbing only.
///
/// `for-each-ref` for every branch and its commit, `symbolic-ref` and `rev-parse` for what is
/// checked out, `reflog` for how a branch moved, `status -z` for uncommitted work. The runner
/// takes no optional lock.
public struct GitActivityReader: RepositoryActivityReading {
  private let git: any GitCommandRunner
  private let roots = RepositoryRootCache()

  public init(git: any GitCommandRunner = ProcessGitCommandRunner()) {
    self.git = git
  }

  public func references(atPath path: String) async -> GitReferenceSnapshot? {
    guard FileManager.default.fileExists(atPath: path),
      let refs = try? await git.run(
        ["for-each-ref", "--format=%(refname)%09%(objectname)", "refs/heads"], in: path),
      refs.succeeded
    else { return nil }

    var branches: [String: String] = [:]
    for line in refs.text.split(separator: "\n") {
      let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
      guard fields.count == 2, let name = GitRepositoryInspector.shortBranch(fields[0]) else {
        continue
      }
      branches[name] = fields[1]
    }
    let symbolic = try? await git.run(["symbolic-ref", "--quiet", "HEAD"], in: path)
    let head = try? await git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: path)
    let status = try? await git.run(
      ["status", "--porcelain=v2", "-z", "--untracked-files=normal"], in: path)

    return GitReferenceSnapshot(
      checkedOutBranch: symbolic.flatMap {
        $0.succeeded ? GitRepositoryInspector.shortBranch($0.text) : nil
      },
      headRevision: head.flatMap { $0.succeeded && !$0.text.isEmpty ? $0.text : nil },
      branches: branches,
      isDirty: status.map { $0.succeeded && !$0.output.isEmpty } ?? false
    )
  }

  public func repositoryRoot(containing path: String) async -> String? {
    await roots.root(containing: path) { [git] folder in
      guard let result = try? await git.run(["rev-parse", "--show-toplevel"], in: folder),
        result.succeeded, !result.text.isEmpty
      else { return nil }
      return CanonicalPath.of(result.text)
    }
  }

  public func reflog(atPath path: String, since date: Date) async -> [ReflogEntry] {
    guard
      let location = try? await git.run(
        ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path),
      location.succeeded
    else { return [] }
    // A branch whose reflog file was not written since the date has nothing to say: reading the
    // file dates first keeps a repository of three hundred branches to a handful of commands.
    let logs = (location.text as NSString).appendingPathComponent("logs/refs/heads")
    var branches: [String] = []
    if let enumerator = FileManager.default.enumerator(atPath: logs) {
      while let relative = enumerator.nextObject() as? String {
        let file = (logs as NSString).appendingPathComponent(relative)
        guard
          let attributes = try? FileManager.default.attributesOfItem(atPath: file),
          attributes[.type] as? FileAttributeType == .typeRegular,
          let modified = attributes[.modificationDate] as? Date, modified > date
        else { continue }
        branches.append(relative)
      }
    }

    var entries: [ReflogEntry] = []
    for branch in branches.sorted() {
      guard
        let result = try? await git.run(
          [
            "reflog", "show", "--date=unix", "--format=%gd%x09%gs", "-n", "500",
            "refs/heads/\(branch)",
          ], in: path),
        result.succeeded
      else { continue }
      for line in result.text.split(separator: "\n") {
        let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard fields.count == 2, let moment = Self.reflogDate(fields[0]), moment > date else {
          continue
        }
        entries.append(ReflogEntry(branch: branch, date: moment, subject: fields[1]))
      }
    }
    return entries.sorted { $0.date < $1.date }
  }

  /// `refs/heads/main@{1790000000}` → the instant between the braces.
  static func reflogDate(_ selector: String) -> Date? {
    guard let open = selector.range(of: "@{", options: .backwards),
      let close = selector.range(of: "}", options: .backwards), open.upperBound < close.lowerBound,
      let seconds = TimeInterval(selector[open.upperBound..<close.lowerBound])
    else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }

  public func hasUncommittedChanges(atPath path: String, since date: Date) async -> Bool {
    guard
      let status = try? await git.run(
        ["status", "--porcelain=v1", "-z", "--untracked-files=normal"], in: path),
      status.succeeded
    else { return false }
    let records = String(decoding: status.output, as: UTF8.self)
      .split(separator: "\0", omittingEmptySubsequences: true)
      .map(String.init)
    var index = 0
    var checked = 0
    while index < records.count, checked < 500 {
      let record = records[index]
      index += 1
      guard record.count > 3 else { continue }
      let code = record.prefix(2)
      // A rename carries the old path as the next field, which has no date of its own.
      if code.contains("R") || code.contains("C") { index += 1 }
      let file = (path as NSString).appendingPathComponent(String(record.dropFirst(3)))
      checked += 1
      if let modified = (try? FileManager.default.attributesOfItem(atPath: file))?[
        .modificationDate] as? Date, modified > date
      {
        return true
      }
    }
    return false
  }
}

/// Which repository each folder belongs to, asked once per folder.
///
/// A transcript names hundreds of files in a handful of folders, and the report is read every
/// thirty seconds: without this, each reading would run `rev-parse` for every one of them.
actor RepositoryRootCache {
  private var known: [String: String?] = [:]

  func root(
    containing path: String,
    resolve: @Sendable (String) async -> String?
  ) async -> String? {
    var folder = path
    var isDirectory: ObjCBool = false
    // A file, or a path that no longer exists: its nearest existing folder is what is asked.
    while !(FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory)
      && isDirectory.boolValue)
    {
      let parent = (folder as NSString).deletingLastPathComponent
      guard parent != folder, !parent.isEmpty else { return nil }
      folder = parent
    }
    if let cached = known[folder] { return cached }
    let answer = await resolve(folder)
    known[folder] = answer
    return answer
  }
}
