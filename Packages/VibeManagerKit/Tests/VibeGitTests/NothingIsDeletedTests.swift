import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeGit
import VibePersistence

/// Every road through the workspace goes through `GuardedGitRunner`, which fails the test the
/// moment a worktree is removed, a branch deleted or a record pruned.
@Suite("Nothing a session made is ever deleted")
struct NothingIsDeletedTests {
  private func storedSession(
    _ workspace: SessionWorkspaceServices,
    clones: [String],
    slug raw: String
  ) async throws -> (InMemorySessionRepository, WorkSession) {
    let plan = await workspace.plan(
      slug: slug(raw), repositories: clones.map { SessionDraftRepository(path: $0) })
    let prepared = await workspace.prepare(plan, attachedAt: Date())
    let session = WorkSession(
      name: raw,
      createdAt: Date(timeIntervalSinceNow: -60),
      updatedAt: Date(timeIntervalSinceNow: -60),
      repositories: prepared,
      slug: slug(raw)
    )
    let repository = InMemorySessionRepository(sessions: [session])
    return (repository, session)
  }

  @Test("A preparation that succeeds, and one that half fails, delete nothing")
  func preparation() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let good = sandbox.path("api")
    try await makeRepository(at: good)
    let bare = sandbox.path("bare.git")
    try FileManager.default.createDirectory(atPath: bare, withIntermediateDirectories: true)
    try await git(["init", "-q", "--bare"], in: bare)
    let workspace = services(runner: GuardedGitRunner(), root: sandbox.worktreeRoot)

    let plan = await workspace.plan(
      slug: slug("guarded"), repositories: [good, bare].map { SessionDraftRepository(path: $0) })
    let prepared = await workspace.prepare(plan, attachedAt: Date())

    #expect(prepared[0].failure == nil)
    #expect(prepared[1].failure != nil)
    #expect(prepared[0].worktreePath.map(fileExists) == true)
  }

  @Test("A preparation cancelled between two repositories keeps the first and deletes nothing")
  func cancellation() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let first = sandbox.path("api")
    let second = sandbox.path("web")
    try await makeRepository(at: first)
    try await makeRepository(at: second)
    let workspace = services(runner: GuardedGitRunner(), root: sandbox.worktreeRoot)
    let plan = await workspace.plan(
      slug: slug("cancelled"),
      repositories: [first, second].map { SessionDraftRepository(path: $0) })

    let task = Task {
      await workspace.prepare(plan, attachedAt: Date()) { progress in
        // The first repository is done: cancelling now stops the queue before the second.
        if case .finished = progress { withUnsafeCurrentTask { $0?.cancel() } }
      }
    }
    let prepared = await task.value

    #expect(prepared.count == 2)
    #expect(prepared[0].failure == nil)
    #expect(prepared[0].worktreePath.map(fileExists) == true)
    #expect(prepared[1].failure != nil)
    #expect(prepared[1].worktreePath == nil)
  }

  @Test("Detaching forgets the repository and leaves its worktree and branch on disk")
  func detaching() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let first = sandbox.path("api")
    let second = sandbox.path("web")
    try await makeRepository(at: first)
    try await makeRepository(at: second)
    let workspace = services(runner: GuardedGitRunner(), root: sandbox.worktreeRoot)
    let (repository, session) = try await storedSession(
      workspace, clones: [first, second], slug: "detached-one")
    let removed = session.repositories[1]

    let detachment = try await DetachRepository(repository: repository)(
      sessionID: session.id, repositoryID: removed.id)

    #expect(detachment.session.repositories.count == 1)
    #expect(detachment.cleanupCommand?.contains("worktree remove") == true)
    #expect(removed.worktreePath.map(fileExists) == true)
    #expect(
      try await git(["branch", "--list", "vibe/detached-one"], in: second).contains(
        "vibe/detached-one"))
  }

  @Test("Closing and archiving a session touch nothing on disk")
  func closingAndArchiving() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let clone = sandbox.path("api")
    try await makeRepository(at: clone)
    let workspace = services(runner: GuardedGitRunner(), root: sandbox.worktreeRoot)
    let (repository, session) = try await storedSession(
      workspace, clones: [clone], slug: "archived")
    var active = session
    try active.reopen(at: Date(timeIntervalSinceNow: -30))
    await repository.save(active)

    _ = try await CloseSession(repository: repository)(id: session.id)
    _ = try await ArchiveSession(repository: repository)(id: session.id)

    let worktree = try #require(session.repositories.first?.worktreePath)
    #expect(fileExists(worktree))
    #expect(
      try await git(["branch", "--list", "vibe/archived"], in: clone).contains("vibe/archived"))
  }

  @Test("Attaching and repairing a repository delete nothing")
  func attachingAndRepairing() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let first = sandbox.path("api")
    let second = sandbox.path("web")
    try await makeRepository(at: first)
    try await makeRepository(at: second)
    let workspace = services(runner: GuardedGitRunner(), root: sandbox.worktreeRoot)
    let (repository, session) = try await storedSession(
      workspace, clones: [first], slug: "grown")

    let attachment = try await AttachRepository(repository: repository, services: workspace)(
      sessionID: session.id, adding: SessionDraftRepository(path: second), isRunning: true)
    #expect(attachment.repository.failure == nil)
    #expect(attachment.addendum != nil)
    #expect(attachment.session.repositories.count == 2)

    // Gone by hand, then recreated: the branch is there, so it is picked up again.
    let worktree = try #require(attachment.repository.worktreePath)
    try await git(["worktree", "remove", "--force", worktree], in: second)
    let repaired = try await RepairRepository(repository: repository, services: workspace)(
      sessionID: session.id, repositoryID: attachment.repository.id)

    #expect(repaired.failure == nil)
    #expect(repaired.worktreePath.map(fileExists) == true)
    #expect(repaired.branchName == "vibe/grown")
  }
}
