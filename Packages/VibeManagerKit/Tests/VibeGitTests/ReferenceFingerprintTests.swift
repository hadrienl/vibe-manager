import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeGit

@Suite("Telling from the disk alone whether a repository's references moved")
struct ReferenceFingerprintTests {
  private func commit(_ message: String, in path: String) async throws {
    let file = URL(fileURLWithPath: path).appendingPathComponent("\(UUID().uuidString).txt")
    try Data(message.utf8).write(to: file)
    try await git(["add", "."], in: path)
    try await git(["commit", "-q", "-m", message], in: path)
  }

  /// Runs `change`, and says whether the fingerprint read before and after differs.
  private func moves(
    _ reader: GitActivityReader, _ path: String, _ change: () async throws -> Void
  ) async throws -> Bool {
    let before = try #require(await reader.referenceFingerprint(atPath: path))
    try await change()
    let after = try #require(await reader.referenceFingerprint(atPath: path))
    return before != after
  }

  @Test("Every way a branch or HEAD moves changes it")
  func movesChangeIt() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let path = sandbox.path("api")
    try await makeRepository(at: path)
    let reader = GitActivityReader()

    #expect(try await moves(reader, path) { try await commit("One", in: path) })
    #expect(try await moves(reader, path) { try await git(["checkout", "-q", "-b", "b"], in: path) })
    #expect(try await moves(reader, path) { try await git(["checkout", "-q", "main"], in: path) })
    #expect(try await moves(reader, path) { try await git(["branch", "-f", "b", "HEAD~1"], in: path) })
    #expect(try await moves(reader, path) { try await git(["reset", "-q", "--hard", "HEAD~1"], in: path) })
    #expect(try await moves(reader, path) { try await git(["pack-refs", "--all"], in: path) })
    #expect(
      try await moves(reader, path) {
        try await git(["update-ref", "--no-create-reflog", "refs/heads/c", "HEAD"], in: path)
      })
  }

  @Test("Reading the status or editing a file leaves it as it was")
  func readingLeavesIt() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let path = sandbox.path("api")
    try await makeRepository(at: path)
    let reader = GitActivityReader()

    #expect(
      try await !moves(reader, path) {
        try await git(["--no-optional-locks", "status"], in: path)
        try Data("edited\n".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent("README"))
      })
  }

  @Test("A worktree sees a commit made in it, and one made in its clone")
  func worktree() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let clone = sandbox.path("api")
    let worktree = sandbox.path("api-feature")
    try await makeRepository(at: clone)
    try await git(["worktree", "add", "-q", "-b", "feature", worktree], in: clone)
    let reader = GitActivityReader()

    #expect(try await moves(reader, worktree) { try await commit("Here", in: worktree) })
    #expect(try await moves(reader, worktree) { try await commit("There", in: clone) })
  }

  @Test("Once the repository's folders are known, no Git runs to take it")
  func noProcess() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let path = sandbox.path("api")
    try await makeRepository(at: path)
    let runner = CountingGit()
    let reader = GitActivityReader(git: runner)

    _ = await reader.referenceFingerprint(atPath: path)
    let known = await runner.count
    for _ in 0..<5 { _ = await reader.referenceFingerprint(atPath: path) }

    #expect(known == 1)
    #expect(await runner.count == known)
  }

  @Test("The report reads the branches once while nothing moves, and again after a commit")
  func reportReadsOnce() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let path = sandbox.path("api")
    try await makeRepository(at: path)
    // The reflog is dated to the second: the session starts strictly after the fixture.
    try await Task.sleep(for: .milliseconds(1_100))
    let startedAt = Date()
    try await Task.sleep(for: .milliseconds(1_100))
    let runner = CountingGit()
    let read = ReadSessionBranchReport(reader: GitActivityReader(git: runner))
    let session = WorkSession(
      name: "API", createdAt: startedAt, updatedAt: startedAt, startedAt: startedAt,
      repositories: [RepositoryContext(path: path)])

    _ = await read(for: session)
    let first = await runner.verbs
    for _ in 0..<20 { _ = await read(for: session) }
    #expect(await runner.verbs == first)

    try await commit("Work", in: path)
    let report = await read(for: session)
    #expect(report.repositories.first?.change?.commitCount == 1)
    #expect(await runner.verbs["reflog", default: 0] > first["reflog", default: 0])
  }
}

/// The real Git, with its commands counted by verb.
private actor CountingGit: GitCommandRunner {
  private let git = ProcessGitCommandRunner()
  private(set) var count = 0
  private(set) var verbs: [String: Int] = [:]

  func run(_ arguments: [String], in directory: String) async throws -> GitCommandResult {
    count += 1
    verbs[arguments.first ?? "", default: 0] += 1
    return try await git.run(arguments, in: directory)
  }
}
