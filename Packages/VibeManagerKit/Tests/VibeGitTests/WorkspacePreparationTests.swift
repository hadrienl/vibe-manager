import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeGit

@Suite("Preparing worktrees in real repositories")
struct WorkspacePreparationTests {
  @Test(
    "A repository whose path has spaces and quotes gets its worktree, and a cleanup that pastes")
  func pathsWithSpaces() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let clone = sandbox.path("Mes Projets", "l'API (v2)")
    try await makeRepository(at: clone)
    let workspace = services(runner: ProcessGitCommandRunner(), root: sandbox.worktreeRoot)

    let plan = await workspace.plan(
      slug: slug("refonte-facturation"),
      repositories: [SessionDraftRepository(path: clone)]
    )
    let prepared = await workspace.prepare(plan, attachedAt: Date())

    let context = try #require(prepared.first)
    #expect(context.failure == nil)
    let worktree = try #require(context.worktreePath)
    #expect(worktree.hasPrefix(sandbox.worktreeRoot))
    #expect(fileExists((worktree as NSString).appendingPathComponent("README")))
    #expect(
      try await git(["symbolic-ref", "--short", "HEAD"], in: worktree) == "vibe/refonte-facturation"
    )
    #expect(context.branchName == "vibe/refonte-facturation")
    #expect(context.createdByVibeManager)

    // The command the inspector offers, pasted into a shell exactly as it is shown.
    let command = try #require(RepositoryCleanupCommand.make(for: context))
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", command]
    shell.standardOutput = FileHandle.nullDevice
    shell.standardError = FileHandle.nullDevice
    try shell.run()
    shell.waitUntilExit()
    #expect(shell.terminationStatus == 0)
    #expect(!fileExists(worktree))
  }

  @Test("A detached HEAD becomes the base of the worktree, and the clone's HEAD does not move")
  func detachedHead() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let clone = sandbox.path("api")
    try await makeRepository(at: clone)
    let head = try await git(["rev-parse", "HEAD"], in: clone)
    try await git(["checkout", "-q", "--detach", "HEAD"], in: clone)
    let workspace = services(runner: ProcessGitCommandRunner(), root: sandbox.worktreeRoot)

    let plan = await workspace.plan(
      slug: slug("detached"), repositories: [SessionDraftRepository(path: clone)])
    let context = try #require(await workspace.prepare(plan, attachedAt: Date()).first)

    let worktree = try #require(context.worktreePath)
    #expect(try await git(["symbolic-ref", "--short", "HEAD"], in: worktree) == "vibe/detached")
    #expect(try await git(["rev-parse", "HEAD"], in: worktree) == head)
    #expect(context.baseRevision == head)
    #expect(try await git(["rev-parse", "HEAD"], in: clone) == head)
    let symbolic = try await ProcessGitCommandRunner().run(
      ["symbolic-ref", "-q", "HEAD"], in: clone)
    #expect(!symbolic.succeeded, "The clone must still be detached")

    let inPlace = await workspace.plan(
      slug: slug("detached-in-place"),
      repositories: [SessionDraftRepository(path: clone, mode: .inPlace)]
    )
    let refused = try #require(inPlace.repositories.first)
    #expect(refused.isBlocked)
    #expect(refused.blockingIssue?.kind == .detachedHead)
    #expect(try await git(["rev-parse", "HEAD"], in: clone) == head)
  }

  @Test("An existing branch checked out nowhere is used as it is, without -b, once asked")
  func existingBranch() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let clone = sandbox.path("api")
    try await makeRepository(at: clone)
    try await git(["branch", "vibe/picked-up"], in: clone)
    let runner = RecordingGitRunner()
    let workspace = services(runner: runner, root: sandbox.worktreeRoot)

    let blocked = await workspace.plan(
      slug: slug("picked-up"), repositories: [SessionDraftRepository(path: clone)])
    #expect(blocked.repositories.first?.blockingIssue?.kind == .branchExists)

    let chosen = SessionDraftRepository(path: clone, choice: .useExistingBranch)
    let plan = await workspace.plan(slug: slug("picked-up"), repositories: [chosen])
    let context = try #require(await workspace.prepare(plan, attachedAt: Date()).first)

    #expect(context.failure == nil)
    let worktree = try #require(context.worktreePath)
    #expect(try await git(["symbolic-ref", "--short", "HEAD"], in: worktree) == "vibe/picked-up")
    #expect(await runner.ran(["worktree", "add"]))
    #expect(!(await runner.ran(["-b"])))
  }

  @Test("A branch checked out elsewhere is adopted into the same context a creation produces")
  func branchCheckedOutElsewhere() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let clone = sandbox.path("api")
    try await makeRepository(at: clone)
    let elsewhere = sandbox.path("elsewhere")
    try await git(["worktree", "add", "-q", "-b", "vibe/shared", elsewhere], in: clone)
    let workspace = services(runner: ProcessGitCommandRunner(), root: sandbox.worktreeRoot)

    let blocked = await workspace.plan(
      slug: slug("shared"), repositories: [SessionDraftRepository(path: clone)])
    let issue = try #require(blocked.repositories.first?.blockingIssue)
    #expect(issue.kind == .branchCheckedOut)
    let adoptPath = try #require(
      issue.resolutions.compactMap { resolution -> String? in
        if case .adoptWorktree(let path) = resolution { return path }
        return nil
      }.first)

    let plan = await workspace.plan(
      slug: slug("shared"),
      repositories: [SessionDraftRepository(path: clone, choice: .adoptWorktree(path: adoptPath))]
    )
    #expect(plan.repositories.first?.action == .adoptWorktree)
    let adopted = try #require(await workspace.prepare(plan, attachedAt: Date()).first)

    // The reference a creation would have produced, on another branch of the same repository.
    let created = try #require(
      await workspace.prepare(
        await workspace.plan(
          slug: slug("fresh"), repositories: [SessionDraftRepository(path: clone)]),
        attachedAt: Date()
      ).first)

    #expect(adopted.rootPath == created.rootPath)
    #expect(adopted.mode == created.mode)
    #expect(adopted.mode == .worktree)
    #expect(adopted.worktreePath.map(CanonicalPath.of) == CanonicalPath.of(elsewhere))
    #expect(adopted.branchName == "vibe/shared")
    #expect(adopted.failure == nil)
    #expect(!adopted.createdByVibeManager)
    #expect(created.createdByVibeManager)
  }

  @Test("Preparing again what is already prepared adopts it and adds nothing")
  func preparationIsIdempotent() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let clone = sandbox.path("api")
    try await makeRepository(at: clone)
    let first = services(runner: ProcessGitCommandRunner(), root: sandbox.worktreeRoot)
    let repository = SessionDraftRepository(path: clone)
    let original = try #require(
      await first.prepare(
        await first.plan(slug: slug("again"), repositories: [repository]), attachedAt: Date()
      ).first)

    let runner = RecordingGitRunner()
    let second = services(runner: runner, root: sandbox.worktreeRoot)
    // As a restart or a repair does it: the repository finds the worktree it already had.
    let plan = await second.plan(
      slug: slug("again"), repositories: [repository], reattaching: [repository.id])
    #expect(plan.repositories.first?.action == .adoptWorktree)
    let again = try #require(await second.prepare(plan, attachedAt: Date()).first)

    #expect(again.failure == nil)
    #expect(again.worktreePath.map(CanonicalPath.of) == original.worktreePath.map(CanonicalPath.of))
    #expect(!(await runner.ran(["worktree", "add"])))
  }

  @Test("A stale worktree record is reported with its command, and never pruned")
  func staleRecord() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let clone = sandbox.path("api")
    try await makeRepository(at: clone)
    let workspace = services(runner: ProcessGitCommandRunner(), root: sandbox.worktreeRoot)
    let repository = SessionDraftRepository(path: clone)
    let prepared = try #require(
      await workspace.prepare(
        await workspace.plan(slug: slug("stale"), repositories: [repository]), attachedAt: Date()
      ).first)
    try FileManager.default.removeItem(atPath: try #require(prepared.worktreePath))

    let runner = RecordingGitRunner()
    let plan = await services(runner: runner, root: sandbox.worktreeRoot)
      .plan(slug: slug("stale"), repositories: [repository])

    let issue = try #require(plan.repositories.first?.blockingIssue)
    #expect(issue.kind == .staleWorktree)
    #expect(issue.command?.contains("worktree prune") == true)
    #expect(!(await runner.ran(["prune"])))
  }

  @Test("One repository in conflict leaves the two others prepared")
  func partialFailure() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let first = sandbox.path("api")
    let second = sandbox.path("web")
    let third = sandbox.path("shared")
    for path in [first, second, third] { try await makeRepository(at: path) }
    try await git(["worktree", "add", "-q", "-b", "vibe/three", sandbox.path("taken")], in: second)
    let workspace = services(runner: ProcessGitCommandRunner(), root: sandbox.worktreeRoot)

    let plan = await workspace.plan(
      slug: slug("three"),
      repositories: [first, second, third].map { SessionDraftRepository(path: $0) }
    )
    let prepared = await workspace.prepare(plan, attachedAt: Date())

    #expect(prepared.count == 3)
    #expect(prepared[0].failure == nil)
    #expect(prepared[0].worktreePath.map(fileExists) == true)
    #expect(prepared[1].failure != nil)
    #expect(prepared[1].worktreePath == nil)
    #expect(prepared[2].failure == nil)
    #expect(prepared[2].worktreePath.map(fileExists) == true)
  }

  @Test("The same repository reached through a link, or through one of its worktrees, is refused")
  func duplicates() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let clone = sandbox.path("real", "api")
    try await makeRepository(at: clone)
    try FileManager.default.createSymbolicLink(
      atPath: sandbox.path("link"), withDestinationPath: sandbox.path("real"))
    let linked = sandbox.path("link", "api")
    let otherWorktree = sandbox.path("other")
    try await git(["worktree", "add", "-q", "-b", "other", otherWorktree], in: clone)
    let workspace = services(runner: ProcessGitCommandRunner(), root: sandbox.worktreeRoot)

    let plan = await workspace.plan(
      slug: slug("dupes"),
      repositories: [clone, linked, otherWorktree].map { SessionDraftRepository(path: $0) }
    )

    #expect(plan.repositories[0].isBlocked == false)
    #expect(plan.repositories[1].blockingIssue?.kind == .duplicate)
    #expect(plan.repositories[2].blockingIssue?.kind == .duplicate)
  }

  @Test("Submodules are said, with their command, and block nothing")
  func submodules() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let library = sandbox.path("library")
    let clone = sandbox.path("app")
    try await makeRepository(at: library)
    try await makeRepository(at: clone)
    try await git(
      ["-c", "protocol.file.allow=always", "submodule", "add", "-q", library, "vendor/library"],
      in: clone)
    try await git(["commit", "-q", "-m", "Add the submodule"], in: clone)
    let workspace = services(runner: ProcessGitCommandRunner(), root: sandbox.worktreeRoot)

    let plan = await workspace.plan(
      slug: slug("modules"), repositories: [SessionDraftRepository(path: clone)])
    let repository = try #require(plan.repositories.first)

    let issue = try #require(repository.issues.first { $0.kind == .submodules })
    #expect(issue.severity == .warning)
    #expect(issue.command?.contains("submodule update --init --recursive") == true)
    #expect(!repository.isBlocked)
    let prepared = try #require(await workspace.prepare(plan, attachedAt: Date()).first)
    #expect(prepared.failure == nil)
  }

  @Test("A bare repository is refused, and a folder without Git is attached as it is")
  func bareAndPlain() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let bare = sandbox.path("bare.git")
    try FileManager.default.createDirectory(atPath: bare, withIntermediateDirectories: true)
    try await git(["init", "-q", "--bare"], in: bare)
    let notes = sandbox.path("notes")
    try FileManager.default.createDirectory(atPath: notes, withIntermediateDirectories: true)
    let workspace = services(runner: ProcessGitCommandRunner(), root: sandbox.worktreeRoot)

    let plan = await workspace.plan(
      slug: slug("mixed"),
      repositories: [notes, bare].map { SessionDraftRepository(path: $0) }
    )

    #expect(plan.repositories[0].action == .plainFolder)
    #expect(plan.repositories[0].mode == .plainFolder)
    #expect(plan.repositories[1].blockingIssue?.kind == .bare)
  }
}
