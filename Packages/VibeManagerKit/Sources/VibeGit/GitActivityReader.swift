import Foundation
import VibeApplication
import VibeDomain

/// Reads a repository's branches for the session report, with plumbing only.
///
/// `symbolic-ref` and `rev-parse` for what is checked out, `reflog` for how a branch moved,
/// `status -z` for uncommitted work. Nothing here writes, and the runner takes no optional lock.
public struct GitActivityReader: RepositoryActivityReading {
  private let git: any GitCommandRunner
  private let roots = RepositoryRootCache()
  private let directories = GitDirectoryCache()

  public init(git: any GitCommandRunner = ProcessGitCommandRunner()) {
    self.git = git
  }

  public func head(atPath path: String) async -> RepositoryHead? {
    guard FileManager.default.fileExists(atPath: path),
      let head = try? await git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: path),
      head.succeeded
    else { return nil }
    let symbolic = try? await git.run(["symbolic-ref", "--quiet", "HEAD"], in: path)
    return RepositoryHead(
      checkedOutBranch: symbolic.flatMap { $0.succeeded ? Self.shortBranch($0.text) : nil })
  }

  static func shortBranch(_ reference: String) -> String? {
    let prefix = "refs/heads/"
    guard reference.hasPrefix(prefix) else { return nil }
    return String(reference.dropFirst(prefix.count))
  }

  public func repositoryRoot(containing path: String) async -> String? {
    await roots.root(containing: path) { [git] folder in
      guard let result = try? await git.run(["rev-parse", "--show-toplevel"], in: folder),
        result.succeeded, !result.text.isEmpty
      else { return nil }
      return CanonicalPath.of(result.text)
    }
  }

  /// Where the repository keeps its state, asked of Git once per repository: a worktree's own
  /// `HEAD` and the clone's shared references are in two different folders.
  func layout(atPath path: String) async -> GitDirectories? {
    if let known = await directories.known(path) { return known }
    guard
      let result = try? await git.run(
        ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: path),
      result.succeeded
    else { return nil }
    let lines = result.text.split(separator: "\n").map(String.init)
    guard lines.count == 2 else { return nil }
    let found = GitDirectories(gitDirectory: lines[0], commonDirectory: lines[1])
    await directories.remember(found, for: path)
    return found
  }

  public func referenceFingerprint(atPath path: String) async -> ReferenceFingerprint? {
    guard FileManager.default.fileExists(atPath: path), let layout = await layout(atPath: path)
    else { return nil }
    return Self.fingerprint(of: layout)
  }

  /// `stat` only, whatever the repository: nothing here runs Git or reads a file's content.
  static func fingerprint(of layout: GitDirectories) -> ReferenceFingerprint? {
    let own = layout.gitDirectory
    let common = layout.commonDirectory
    // Without its `HEAD`, the folder is no longer a repository: the branches are read again, and
    // say so.
    guard let head = stamp(of: (own as NSString).appendingPathComponent("HEAD")) else {
      return nil
    }
    var stamps = ["HEAD": head]
    for (key, file) in [
      ("logs/HEAD", (own as NSString).appendingPathComponent("logs/HEAD")),
      ("packed-refs", (common as NSString).appendingPathComponent("packed-refs")),
      ("reftable", (common as NSString).appendingPathComponent("reftable/tables.list")),
    ] {
      if let found = stamp(of: file) { stamps[key] = found }
    }
    for folder in ["logs/refs/heads", "refs/heads"] {
      let root = (common as NSString).appendingPathComponent(folder)
      guard let enumerator = FileManager.default.enumerator(atPath: root) else { continue }
      while let relative = enumerator.nextObject() as? String {
        let file = (root as NSString).appendingPathComponent(relative)
        if let found = stamp(of: file, regularOnly: true) {
          stamps["\(folder)/\(relative)"] = found
        }
      }
    }
    return ReferenceFingerprint(stamps: stamps)
  }

  private static func stamp(of file: String, regularOnly: Bool = false)
    -> ReferenceFingerprint.Stamp?
  {
    var info = stat()
    guard lstat(file, &info) == 0 else { return nil }
    if regularOnly, info.st_mode & S_IFMT != S_IFREG { return nil }
    return ReferenceFingerprint.Stamp(
      inode: UInt64(info.st_ino), size: Int64(info.st_size),
      modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
        + Int64(info.st_mtimespec.tv_nsec))
  }

  public func reflog(atPath path: String, since date: Date) async -> [ReflogEntry] {
    guard let layout = await layout(atPath: path) else { return [] }
    // A branch whose reflog file was not written since the date has nothing to say: reading the
    // file dates first keeps a repository of three hundred branches to a handful of commands.
    let logs = (layout.commonDirectory as NSString).appendingPathComponent("logs/refs/heads")
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
