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

  @Test("A reftable worktree sees its own checkout, kept in its own stack")
  func reftableWorktree() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let clone = sandbox.path("api")
    let worktree = sandbox.path("api-feature")
    try FileManager.default.createDirectory(atPath: clone, withIntermediateDirectories: true)
    // Git older than 2.45 has no reftable: nothing to check there.
    let created = try await ProcessGitCommandRunner().run(
      ["init", "-q", "--ref-format=reftable", "-b", "main"], in: clone)
    guard created.succeeded else { return }
    try await git(["config", "user.name", "Vibe Tests"], in: clone)
    try await git(["config", "user.email", "tests@example.com"], in: clone)
    try await git(["config", "commit.gpgsign", "false"], in: clone)
    try await commit("Initial", in: clone)
    try await commit("Second", in: clone)
    try await git(["worktree", "add", "-q", "-b", "feature", worktree], in: clone)
    let reader = GitActivityReader()

    #expect(
      try await moves(reader, worktree) {
        try await git(["checkout", "-q", "--detach", "HEAD~1"], in: worktree)
      })
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
    // The reflog is dated to the second: the fixture is dated an hour back, and the session starts
    // two seconds back, so the commit made below falls after it without waiting for the clock.
    try await makeRepository(at: path, dated: Date().addingTimeInterval(-3_600))
    let startedAt = Date().addingTimeInterval(-2)
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

/// A repository with one commit on `main`, its commit and reflog dated `date`: Git takes the date
/// from the environment, which the application's runner does not pass on.
private func makeRepository(at path: String, dated date: Date) async throws {
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  try Data("hello\n".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent("README"))
  let stamp = "@\(Int(date.timeIntervalSince1970)) +0000"
  for arguments in [
    ["init", "-q", "-b", "main"], ["add", "README"],
    [
      "-c", "user.name=Vibe Tests", "-c", "user.email=tests@example.com", "-c",
      "commit.gpgsign=false", "commit", "-q", "-m", "Initial commit",
    ],
  ] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_AUTHOR_DATE"] = stamp
    environment["GIT_COMMITTER_DATE"] = stamp
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
  }
  try await git(["config", "user.name", "Vibe Tests"], in: path)
  try await git(["config", "user.email", "tests@example.com"], in: path)
  try await git(["config", "commit.gpgsign", "false"], in: path)
}
