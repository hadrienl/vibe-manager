import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeGit

@Suite("Reading what a branch committed")
struct BranchCommitsTests {
  private let reader = GitStatusReader()

  private func write(_ text: String, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private func committed(_ path: String) async throws -> BranchCommits? {
    try await reader.status(atPath: path, limit: 5_000).get().committed
  }

  @Test("A branch's commits are listed against main, renames and deletions included")
  func againstLocalMain() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let repository = sandbox.path("api")
    try await makeRepository(at: repository)
    try write("one\ntwo\nthree\nfour\n", to: repository + "/old name.txt")
    try write("doomed\n", to: repository + "/doomed.txt")
    try await git(["add", "."], in: repository)
    try await git(["commit", "-q", "-m", "Base"], in: repository)

    try await git(["checkout", "-q", "-b", "feat/x"], in: repository)
    try write("new\n", to: repository + "/Sources/New.swift")
    try await git(["add", "."], in: repository)
    try await git(["commit", "-q", "-m", "Add"], in: repository)
    try await git(["mv", "old name.txt", "new name.txt"], in: repository)
    try await git(["rm", "-q", "doomed.txt"], in: repository)
    try await git(["commit", "-q", "-m", "Move"], in: repository)

    let commits = try #require(try await committed(repository))
    #expect(commits.base == "main")
    #expect(commits.commitCount == 2)
    #expect(commits.totalCount == 3)
    #expect(
      Set(commits.files) == [
        CommittedFile(path: "Sources/New.swift", change: .added),
        CommittedFile(path: "doomed.txt", change: .deleted),
        CommittedFile(
          path: "new name.txt", change: .renamed(from: "old name.txt", similarity: 100)),
      ])

    // Committed again: the list moves with `HEAD`, whatever was read before.
    try write("more\n", to: repository + "/README")
    try await git(["commit", "-q", "-am", "More"], in: repository)
    let again = try #require(try await committed(repository))
    #expect(again.commitCount == 3)
    #expect(again.files.contains(CommittedFile(path: "README", change: .modified)))
  }

  @Test("The diff is run only when HEAD moves; a Git that fails keeps the last list")
  func cacheAndFailure() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let repository = sandbox.path("api")
    try await makeRepository(at: repository)
    try await git(["checkout", "-q", "-b", "feat/x"], in: repository)
    try write("new\n", to: repository + "/a.txt")
    try await git(["add", "."], in: repository)
    try await git(["commit", "-q", "-m", "A"], in: repository)

    let runner = CountingRunner()
    let reader = GitStatusReader(git: runner)
    let first = try await reader.status(atPath: repository, limit: 100).get().committed
    try write("saved, not committed\n", to: repository + "/a.txt")
    let second = try await reader.status(atPath: repository, limit: 100).get().committed
    #expect(first?.files == [CommittedFile(path: "a.txt", change: .added)])
    #expect(second == first)
    #expect(await runner.diffs == 1)

    try await git(["commit", "-q", "-am", "B"], in: repository)
    await runner.setFailing(true)
    let failed = try await reader.status(atPath: repository, limit: 100).get().committed
    #expect(failed == first)
    await runner.setFailing(false)
    let recovered = try await reader.status(atPath: repository, limit: 100).get().committed
    #expect(recovered?.commitCount == 2)
  }

  @Test("On main, with nothing the base lacks, nothing is listed")
  func nothingAhead() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let repository = sandbox.path("api")
    try await makeRepository(at: repository)
    #expect(try await committed(repository) == nil)
  }

  @Test("A clone compares with the branch origin/HEAD names, and main shows what is not pushed")
  func againstTheRemote() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let origin = sandbox.path("origin")
    try await makeRepository(at: origin)
    try await git(["branch", "-m", "trunk"], in: origin)
    let clone = sandbox.path("clone")
    try await git(["clone", "-q", origin, clone], in: sandbox.root)
    try await git(["config", "user.name", "Vibe Tests"], in: clone)
    try await git(["config", "user.email", "tests@example.com"], in: clone)
    try await git(["config", "commit.gpgsign", "false"], in: clone)
    #expect(try await committed(clone) == nil)

    try write("local\n", to: clone + "/local.txt")
    try await git(["add", "."], in: clone)
    try await git(["commit", "-q", "-m", "Not pushed"], in: clone)

    let commits = try #require(try await committed(clone))
    #expect(commits.base == "origin/trunk")
    #expect(commits.commitCount == 1)
    #expect(commits.files == [CommittedFile(path: "local.txt", change: .added)])
  }

  @Test("Every file is counted, the first ones kept")
  func limit() {
    let output = Data("M\0a\0A\0b\0R087\0c\0d\0D\0e\0".utf8)
    let (files, total) = GitDiffParser.parse(output, limit: 2)
    #expect(total == 4)
    #expect(
      files == [
        CommittedFile(path: "a", change: .modified), CommittedFile(path: "b", change: .added),
      ])
    let all = GitDiffParser.parse(output, limit: 10).files
    #expect(all[2] == CommittedFile(path: "d", change: .renamed(from: "c", similarity: 87)))
    #expect(all[3] == CommittedFile(path: "e", change: .deleted))
  }

  @Test("The base is the first reference that exists, origin/HEAD named after its target")
  func base() {
    let records = [
      "refs/heads/main\u{0}aaa\u{0}",
      "refs/remotes/origin/HEAD\u{0}bbb\u{0}refs/remotes/origin/develop",
      "refs/remotes/origin/main\u{0}ccc\u{0}",
    ].joined(separator: "\n")
    let base = GitStatusReader.base(from: records)
    #expect(base?.name == "origin/develop")
    #expect(base?.revision == "bbb")
    #expect(GitStatusReader.base(from: "refs/heads/master\u{0}ddd\u{0}")?.name == "master")
    #expect(GitStatusReader.base(from: "") == nil)
  }
}

/// The real Git, with its diffs counted, and refused on demand.
private actor CountingRunner: GitCommandRunner {
  private let git = ProcessGitCommandRunner()
  private(set) var diffs = 0
  private var failing = false

  func setFailing(_ value: Bool) { failing = value }

  func run(_ arguments: [String], in directory: String) async throws -> GitCommandResult {
    if arguments.first == "diff" {
      diffs += 1
      if failing { return GitCommandResult(exitCode: -1) }
    }
    return try await git.run(arguments, in: directory)
  }
}
