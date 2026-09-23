import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeGit

@Suite("Two sessions prepared at once on one repository")
struct ConcurrentPreparationTests {
  private func prepareInParallel(
    _ first: SessionWorkspaceServices,
    _ second: SessionWorkspaceServices,
    clone: String
  ) async -> ([RepositoryContext], [RepositoryContext]) {
    let repository = SessionDraftRepository(path: clone)
    async let left = first.prepare(
      await first.plan(slug: slug("left"), repositories: [repository]), attachedAt: Date())
    async let right = second.prepare(
      await second.plan(slug: slug("right"), repositories: [repository]), attachedAt: Date())
    return await (left, right)
  }

  @Test("One writer serialises both: two worktrees, two branches, no index.lock")
  func sharedService() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let clone = sandbox.path("api")
    try await makeRepository(at: clone)
    let workspace = services(runner: ProcessGitCommandRunner(), root: sandbox.worktreeRoot)

    let (left, right) = await prepareInParallel(workspace, workspace, clone: clone)

    #expect(left.first?.failure == nil)
    #expect(right.first?.failure == nil)
    #expect(left.first?.worktreePath.map(fileExists) == true)
    #expect(right.first?.worktreePath.map(fileExists) == true)
    let branches = try await git(["branch", "--list", "vibe/*"], in: clone)
    #expect(branches.contains("vibe/left"))
    #expect(branches.contains("vibe/right"))
  }

  @Test("Two writers sharing one queue serialise just the same")
  func sharedSerializer() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let clone = sandbox.path("api")
    try await makeRepository(at: clone)
    let serializer = GitWriteSerializer()
    let first = services(
      runner: ProcessGitCommandRunner(), root: sandbox.worktreeRoot, serializer: serializer)
    let second = services(
      runner: ProcessGitCommandRunner(), root: sandbox.worktreeRoot, serializer: serializer)

    let (left, right) = await prepareInParallel(first, second, clone: clone)

    #expect(left.first?.failure == nil)
    #expect(right.first?.failure == nil)
    let worktrees = try await git(["worktree", "list", "--porcelain"], in: clone)
    #expect(worktrees.contains("refs/heads/vibe/left"))
    #expect(worktrees.contains("refs/heads/vibe/right"))
  }
}
