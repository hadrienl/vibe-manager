import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeGit

@Suite("Reading a real repository's working tree")
struct GitStatusReaderTests {
  private let reader = GitStatusReader()

  private func write(_ text: String, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private func status(_ path: String) async throws -> WorkingTreeStatus {
    try await reader.status(atPath: path, limit: 5_000).get()
  }

  private func kind(_ status: WorkingTreeStatus, _ path: String) -> WorkingTreeEntry.Kind? {
    status.entries.first { $0.path == path }?.kind
  }

  @Test("Staged, unstaged, both, renamed, deleted and untracked are told apart")
  func everyKindOfChange() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let repository = sandbox.path("api")
    try await makeRepository(at: repository)
    // Each its own content: two identical files would let Git pair a deletion with another
    // file's rename.
    for name in ["both.txt", "gone.txt", "removed.txt", "moved.txt", "renamed.txt"] {
      try write(
        "\(name), line one\n\(name), line two\n\(name), line three\n", to: repository + "/" + name)
    }
    try await git(["add", "."], in: repository)
    try await git(["commit", "-q", "-m", "Files"], in: repository)

    try write("staged\n", to: repository + "/both.txt")
    try await git(["add", "both.txt"], in: repository)
    try write("staged, then changed\n", to: repository + "/both.txt")
    try await git(["rm", "-q", "removed.txt"], in: repository)
    try FileManager.default.removeItem(atPath: repository + "/gone.txt")
    try await git(["mv", "renamed.txt", "renamed now.txt"], in: repository)
    try FileManager.default.moveItem(
      atPath: repository + "/moved.txt", toPath: repository + "/moved away.txt")
    try write("new\n", to: repository + "/Generated/deep/file.swift")
    try write("new\n", to: repository + "/loose.txt")

    let status = try await status(repository)

    #expect(kind(status, "both.txt") == .tracked(staged: .modified, unstaged: .modified))
    #expect(kind(status, "removed.txt") == .tracked(staged: .deleted, unstaged: nil))
    #expect(kind(status, "gone.txt") == .tracked(staged: nil, unstaged: .deleted))
    #expect(
      kind(status, "renamed now.txt")
        == .tracked(staged: .renamed(from: "renamed.txt", similarity: 100), unstaged: nil))
    // Git reports a move it was not told about as a deletion and a new file, and so do we.
    #expect(kind(status, "moved.txt") == .tracked(staged: nil, unstaged: .deleted))
    #expect(kind(status, "moved away.txt") == .untracked)
    #expect(kind(status, "Generated/") == .untrackedDirectory)
    #expect(kind(status, "loose.txt") == .untracked)
    #expect(status.branch.branchName == "main")
    #expect(!status.isClean)
  }

  @Test("A merge that stopped on a conflict is said, file and operation")
  func conflict() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let repository = sandbox.path("api")
    try await makeRepository(at: repository)
    try await git(["checkout", "-q", "-b", "other"], in: repository)
    try write("theirs\n", to: repository + "/README")
    try await git(["commit", "-q", "-am", "Theirs"], in: repository)
    try await git(["checkout", "-q", "main"], in: repository)
    try write("ours\n", to: repository + "/README")
    try await git(["commit", "-q", "-am", "Ours"], in: repository)
    _ = try? await ProcessGitCommandRunner().run(["merge", "-q", "other"], in: repository)

    let status = try await status(repository)

    #expect(kind(status, "README") == .conflicted(.bothModified))
    #expect(status.operation == .merging)
    #expect(status.counts.conflicted == 1)
  }

  @Test("Names Git would quote are read as they are on disk")
  func unusualNames() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let repository = sandbox.path("Mes Projets", "l'API (v2)")
    try await makeRepository(at: repository)
    let names = [
      "with space.txt", "quote\"d.txt", "tab\there.txt", "new\nline.txt", "café.txt", "-dash",
      "🚀.md",
    ]
    for name in names { try write("x\n", to: repository + "/" + name) }

    let status = try await status(repository)

    #expect(Set(status.entries.map(\.path)) == Set(names))
  }

  @Test("A detached HEAD and an empty repository are read, not refused")
  func detachedAndInitial() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let repository = sandbox.path("api")
    try await makeRepository(at: repository)
    try await git(["checkout", "-q", "--detach"], in: repository)
    let detached = try await status(repository)
    #expect(detached.branch.branchName == nil)
    #expect(detached.branch.headRevision != nil)

    let empty = sandbox.path("empty")
    try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
    try await git(["init", "-q", "-b", "main"], in: empty)
    let initial = try await status(empty)
    #expect(initial.branch.headRevision == nil)
    #expect(initial.branch.branchName == "main")
  }

  @Test("Ahead and behind come from the local references, with no network")
  func aheadAndBehind() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let remote = sandbox.path("remote.git")
    let repository = sandbox.path("api")
    let colleague = sandbox.path("colleague")
    try FileManager.default.createDirectory(atPath: remote, withIntermediateDirectories: true)
    try await git(["init", "-q", "--bare", "-b", "main"], in: remote)
    try await makeRepository(at: repository)
    try await git(["remote", "add", "origin", remote], in: repository)
    try await git(["push", "-q", "-u", "origin", "main"], in: repository)
    try await git(["clone", "-q", remote, colleague], in: sandbox.root)
    try await git(["config", "user.name", "Colleague"], in: colleague)
    try await git(["config", "user.email", "colleague@example.com"], in: colleague)
    try await git(["config", "commit.gpgsign", "false"], in: colleague)
    try write("theirs\n", to: colleague + "/theirs.txt")
    try await git(["add", "."], in: colleague)
    try await git(["commit", "-q", "-m", "Theirs"], in: colleague)
    try await git(["push", "-q"], in: colleague)
    try await git(["fetch", "-q"], in: repository)
    for index in 0..<2 {
      try write("\(index)\n", to: repository + "/ours-\(index).txt")
      try await git(["add", "."], in: repository)
      try await git(["commit", "-q", "-m", "Ours \(index)"], in: repository)
    }

    let status = try await status(repository)

    #expect(status.branch.upstream == "origin/main")
    #expect(status.branch.ahead == 2)
    #expect(status.branch.behind == 1)
  }

  @Test("Reading never writes: with another Git holding the index, it succeeds and leaves it alone")
  func readingTakesNoLock() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let repository = sandbox.path("api")
    try await makeRepository(at: repository)
    try write("changed\n", to: repository + "/README")
    let index = repository + "/.git/index"
    let lock = repository + "/.git/index.lock"
    // An index whose stat data is stale is exactly what a plain `git status` would rewrite.
    try await Task.sleep(for: .milliseconds(1_100))
    let before = try Data(contentsOf: URL(fileURLWithPath: index))
    let beforeDate =
      try FileManager.default.attributesOfItem(atPath: index)[.modificationDate]
      as? Date
    let beforeListing = try FileManager.default.contentsOfDirectory(atPath: repository + "/.git")
    FileManager.default.createFile(atPath: lock, contents: Data())

    let status = try await status(repository)

    #expect(kind(status, "README") == .tracked(staged: nil, unstaged: .modified))
    #expect(status.indexLock?.path.hasSuffix(".git/index.lock") == true)
    #expect(try Data(contentsOf: URL(fileURLWithPath: index)) == before)
    #expect(
      try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date
        == beforeDate)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: repository + "/.git").sorted()
        == (beforeListing + ["index.lock"]).sorted())
  }

  @Test(
    "An untracked folder unfolds into its files, names as they are on disk, and nothing written")
  func untrackedFolder() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let repository = sandbox.path("api")
    try await makeRepository(at: repository)
    let odd = "line\nbreak.txt"
    try write("a\n", to: repository + "/Generated/one.swift")
    try write("b\n", to: repository + "/Generated/deep/two.swift")
    try write("c\n", to: repository + "/Generated/" + odd)
    // A sibling whose name the folder's name is a prefix of, and a folder named like a pattern:
    // neither may leak into the other's listing.
    try write("d\n", to: repository + "/Generated-old/three.swift")
    try write("e\n", to: repository + "/[draft]*/four.swift")
    let beforeListing = try FileManager.default.contentsOfDirectory(atPath: repository + "/.git")

    let status = try await status(repository)
    #expect(kind(status, "Generated/") == .untrackedDirectory)

    let listing = try await reader.untrackedFiles(
      in: "Generated/", atPath: repository, limit: 100
    ).get()
    #expect(
      Set(listing.paths)
        == ["Generated/one.swift", "Generated/deep/two.swift", "Generated/" + odd])
    #expect(listing.totalCount == 3)
    #expect(!listing.isTruncated)

    let pattern = try await reader.untrackedFiles(in: "[draft]*/", atPath: repository, limit: 100)
      .get()
    #expect(pattern.paths == ["[draft]*/four.swift"])

    let cut = try await reader.untrackedFiles(in: "Generated/", atPath: repository, limit: 2).get()
    #expect(cut.paths.count == 2)
    #expect(cut.totalCount == 3)
    #expect(cut.isTruncated)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: repository + "/.git").sorted()
        == beforeListing.sorted())
  }

  @Test("A linked worktree says where its own state lives, outside the worktree")
  func linkedWorktree() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let repository = sandbox.path("api")
    try await makeRepository(at: repository)
    let worktree = sandbox.path("trees", "oauth")
    try await git(["worktree", "add", "-q", "-b", "oauth", worktree], in: repository)

    let directories = try await reader.gitDirectories(atPath: worktree).get()

    #expect(CanonicalPath.of(directories.commonDirectory) == CanonicalPath.of(repository + "/.git"))
    #expect(
      CanonicalPath.of(directories.gitDirectory)
        == CanonicalPath.of(repository + "/.git/worktrees/oauth"))
    #expect(try await status(worktree).branch.branchName == "oauth")
  }

  @Test("A missing folder, a folder that is not a repository, and a closed one are told apart")
  func failures() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let missing = sandbox.path("missing")
    #expect(await reader.status(atPath: missing, limit: 10) == .failure(.missing(path: missing)))

    let plain = sandbox.path("plain")
    try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
    #expect(
      await reader.status(atPath: plain, limit: 10) == .failure(.notARepository(path: plain)))

    let closed = sandbox.path("closed")
    try await makeRepository(at: closed)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed)
    }
    #expect(
      await reader.status(atPath: closed, limit: 10) == .failure(.permissionDenied(path: closed)))
  }

  @Test("A large output is cut to the limit with exact counts")
  func largeOutput() async throws {
    let reader = GitStatusReader(git: CannedRunner(output: Self.untracked(200_000)))
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let status = try await reader.status(atPath: sandbox.root, limit: 5_000).get()

    #expect(status.entries.count == 5_000)
    #expect(status.counts.untracked == 200_000)
    #expect(status.isTruncated == true)
  }

  @MainActor
  @Test("A reading never needs the main actor")
  func readingOffTheMainActor() async throws {
    let reader = GitStatusReader(git: CannedRunner(output: Self.untracked(1_000)))
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let box = StatusBox()
    let finished = DispatchSemaphore(value: 0)
    let root = sandbox.root
    Task.detached {
      box.value = try? await reader.status(atPath: root, limit: 5_000).get()
      finished.signal()
    }
    // The main actor is held until the reading ends: one that needed it would never end. Timing
    // how long the main actor waited would time every other suite sharing it in this process. The
    // output is small, so that the other suites wait a few milliseconds, not the whole parse.
    #expect(MainActorHold.until(finished, atMost: .seconds(30)))
    #expect(box.value?.counts.untracked == 1_000)
  }

  private static func untracked(_ count: Int) -> Data {
    let records = (0..<count).map { "? generated/file-\($0).txt" }
    return Data((records.joined(separator: "\0") + "\0").utf8)
  }
}

/// Answers every command with the same output, as fast as it can.
private struct CannedRunner: GitCommandRunner {
  let output: Data

  func run(_ arguments: [String], in directory: String) async throws -> GitCommandResult {
    if arguments.first == "rev-parse" {
      return GitCommandResult(exitCode: 0, text: "\(directory)/.git\n\(directory)/.git\n")
    }
    return GitCommandResult(exitCode: 0, output: output)
  }
}

/// Carries a result out of a detached task.
private final class StatusBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: WorkingTreeStatus?

  var value: WorkingTreeStatus? {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

/// Blocks the calling thread — the main one, in the test above — until `semaphore` is signalled.
enum MainActorHold {
  static func until(_ semaphore: DispatchSemaphore, atMost limit: Duration) -> Bool {
    let seconds = Double(limit.components.seconds)
    return semaphore.wait(timeout: .now() + seconds) == .success
  }
}
