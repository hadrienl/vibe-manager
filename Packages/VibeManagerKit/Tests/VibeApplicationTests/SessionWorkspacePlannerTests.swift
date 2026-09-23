import Foundation
import Testing
import VibeApplication
import VibeDomain

@Suite("Planning the repositories of a session")
struct SessionWorkspacePlannerTests {
  private let planner = SessionWorkspacePlanner()
  private let sessionSlug = slug("refonte-facturation")
  private var branch: String { sessionSlug.branchName }
  private var target: String { "/wt/refonte-facturation/api" }

  private func plan(
    _ candidates: [(SessionDraftRepository, RepositoryInspection)],
    occupied: Set<String> = [],
    taken: [String: String] = [:]
  ) -> SessionWorkspacePlan {
    planner.plan(
      SessionWorkspacePlanner.Input(
        slug: sessionSlug,
        worktreeRootPath: workspaceRoot,
        candidates: candidates.map { .init(repository: $0.0, inspection: $0.1) },
        occupiedPaths: occupied,
        takenSlugs: taken
      )
    )
  }

  private func single(
    _ inspection: RepositoryInspection,
    mode: RepositoryAttachmentMode? = nil,
    base: RepositoryBase = .head,
    choice: RepositoryConflictChoice? = nil,
    occupied: Set<String> = []
  ) throws -> RepositoryPlan {
    let repository = SessionDraftRepository(
      path: "/work/api", mode: mode, base: base, choice: choice)
    return try #require(plan([(repository, inspection)], occupied: occupied).repositories.first)
  }

  private func kinds(_ plan: RepositoryPlan) -> [RepositoryAttachmentIssue.Kind] {
    plan.issues.map(\.kind)
  }

  // MARK: - The ordinary cases

  @Test("A Git repository gets a worktree on the session branch, from its HEAD")
  func repositoryGetsAWorktree() throws {
    let result = try single(.repository(repositoryFacts("/work/api")))

    #expect(result.action == .createWorktree(createsBranch: true))
    #expect(result.worktreePath == target)
    #expect(result.branchName == branch)
    #expect(result.baseLabel == "main at 3f2a1c9")
    #expect(result.createdByVibeManager)
    #expect(result.issues.isEmpty)
  }

  @Test("A folder without Git is attached as a plain folder, with a notice and its ways out")
  func plainFolder() throws {
    let result = try single(.plainFolder)

    #expect(result.action == .plainFolder)
    #expect(result.mode == .plainFolder)
    #expect(kinds(result) == [.notARepository])
    #expect(result.issues[0].severity == .notice)
    #expect(result.issues[0].resolutions == [.keepAsPlainFolder, .chooseAnotherFolder])
  }

  @Test("A folder that is gone is held back with the sentence the draft already uses")
  func missingFolder() throws {
    let result = try single(.unusable(.missing))

    #expect(result.isBlocked)
    #expect(result.blockingIssue?.message == SessionDraftIssue.workingDirectoryNotFound.message)
  }

  // MARK: - The branch

  @Test("An existing branch checked out nowhere is a conflict, with two ways out")
  func existingBranch() throws {
    let result = try single(
      .repository(repositoryFacts("/work/api", branches: ["main", branch])))

    #expect(result.isBlocked)
    #expect(kinds(result) == [.branchExists])
    #expect(
      result.blockingIssue?.resolutions == [
        .useExistingBranch, .changeSlug(suggestion: "refonte-facturation-2"),
      ])
  }

  @Test("Choosing the existing branch puts the worktree on it, without -b")
  func useExistingBranch() throws {
    let result = try single(
      .repository(repositoryFacts("/work/api", branches: ["main", branch])),
      choice: .useExistingBranch
    )

    #expect(result.action == .createWorktree(createsBranch: false))
    #expect(result.worktreePath == target)
  }

  @Test("A branch checked out elsewhere is a conflict, whose resolution names that worktree")
  func branchCheckedOutElsewhere() throws {
    let elsewhere = GitWorktreeRecord(path: "/work/api-other", branchName: branch)
    let facts = repositoryFacts("/work/api", branches: ["main", branch], worktrees: [elsewhere])
    let result = try single(.repository(facts))

    #expect(result.isBlocked)
    #expect(kinds(result) == [.branchCheckedOut])
    #expect(result.blockingIssue?.resolutions.first == .adoptWorktree(path: "/work/api-other"))
  }

  @Test("Adopting that worktree works in it, and does not claim the application made it")
  func adoptWorktree() throws {
    let elsewhere = GitWorktreeRecord(path: "/work/api-other", branchName: branch)
    let facts = repositoryFacts("/work/api", branches: ["main", branch], worktrees: [elsewhere])
    let result = try single(.repository(facts), choice: .adoptWorktree(path: "/work/api-other"))

    #expect(result.action == .adoptWorktree)
    #expect(result.worktreePath == "/work/api-other")
    #expect(!result.createdByVibeManager)
    #expect(result.context(attachedAt: Date()).worktreePath == "/work/api-other")
  }

  @Test("A repository of the session finds its own worktree again without a question")
  func preparedTwiceIsAdopted() throws {
    let prepared = GitWorktreeRecord(path: target, branchName: branch)
    let facts = repositoryFacts("/work/api", branches: ["main", branch], worktrees: [prepared])
    let repository = SessionDraftRepository(path: "/work/api")
    let result = try #require(
      planner.plan(
        SessionWorkspacePlanner.Input(
          slug: sessionSlug,
          worktreeRootPath: workspaceRoot,
          candidates: [.init(repository: repository, inspection: .repository(facts))],
          reattaching: [repository.id]
        )
      ).repositories.first)

    #expect(result.action == .adoptWorktree)
    #expect(result.worktreePath == target)
    #expect(result.issues.isEmpty)
  }

  @Test("At creation, a worktree found where the new one would go is someone else's until said")
  func worktreeAtTargetIsNotAdoptedAtCreation() throws {
    // An archived session named the same way left it there: working in it silently would put
    // the new session on top of the old one's work.
    let left = GitWorktreeRecord(path: target, branchName: branch)
    let facts = repositoryFacts("/work/api", branches: ["main", branch], worktrees: [left])
    let result = try single(.repository(facts))

    #expect(result.isBlocked)
    #expect(kinds(result) == [.branchCheckedOut])
    #expect(result.blockingIssue?.resolutions.contains(.adoptWorktree(path: target)) == true)
  }

  // MARK: - The path

  @Test("Something already at the worktree path is a conflict, with another folder offered")
  func occupiedPath() throws {
    let result = try single(.repository(repositoryFacts("/work/api")), occupied: [target])

    #expect(kinds(result) == [.pathOccupied])
    #expect(
      result.blockingIssue?.resolutions.contains(
        .chooseAnotherSubfolder(suggestion: "work-api")) == true)
  }

  @Test("A stale record at the worktree path is shown with prune to copy, never run")
  func staleRecord() throws {
    let stale = GitWorktreeRecord(path: target, isPrunable: true)
    let result = try single(.repository(repositoryFacts("/work/api", worktrees: [stale])))

    #expect(kinds(result) == [.staleWorktree])
    #expect(result.blockingIssue?.command == "git -C /work/api worktree prune")
  }

  @Test("A locked worktree says why it is locked, and gives unlock to copy")
  func lockedWorktree() throws {
    let locked = GitWorktreeRecord(
      path: target, branchName: branch, isLocked: true, lockReason: "on a USB disk")
    let facts = repositoryFacts("/work/api", branches: ["main", branch], worktrees: [locked])
    let result = try single(.repository(facts))

    #expect(kinds(result) == [.lockedWorktree])
    #expect(result.blockingIssue?.message.contains("on a USB disk") == true)
    #expect(
      result.blockingIssue?.command
        == "git -C /work/api worktree unlock /wt/refonte-facturation/api")
  }

  // MARK: - The state of the clone

  @Test("A dirty clone prevents nothing in a worktree, and is only a reminder")
  func dirtyInWorktree() throws {
    let result = try single(.repository(repositoryFacts("/work/api", dirty: true)))

    #expect(result.action == .createWorktree(createsBranch: true))
    #expect(kinds(result) == [.dirty])
    #expect(result.issues[0].severity == .notice)
  }

  @Test("A dirty clone attached in place is a warning, which offers the worktree instead")
  func dirtyInPlace() throws {
    let result = try single(
      .repository(repositoryFacts("/work/api", dirty: true)), mode: .inPlace)

    #expect(result.action == .inPlace(createsBranch: false))
    #expect(result.branchName == "main")
    #expect(result.issues.first?.severity == .warning)
    #expect(result.issues.first?.resolutions == [.switchToWorktree])
  }

  @Test("A detached HEAD starts a worktree from its commit")
  func detachedInWorktree() throws {
    let result = try single(.repository(repositoryFacts("/work/api", branch: nil)))

    #expect(result.action == .createWorktree(createsBranch: true))
    #expect(result.baseLabel == "detached HEAD at 3f2a1c9")
    #expect(result.baseRevision == "3f2a1c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b")
  }

  @Test("A detached HEAD cannot be worked in place, unless the branch is created there")
  func detachedInPlace() throws {
    let facts = repositoryFacts("/work/api", branch: nil)
    let refused = try single(.repository(facts), mode: .inPlace)
    let accepted = try single(.repository(facts), mode: .inPlace, choice: .createBranchInPlace)

    #expect(refused.isBlocked)
    #expect(kinds(refused) == [.detachedHead])
    #expect(accepted.action == .inPlace(createsBranch: true))
    #expect(accepted.branchName == branch)
  }

  @Test("A bare repository has nothing to work in")
  func bareRepository() throws {
    let result = try single(.bare(commonDirectory: "/work/api.git"))

    #expect(result.isBlocked)
    #expect(kinds(result) == [.bare])
  }

  @Test("Submodules are a warning, with the command that initialises them")
  func submodules() throws {
    let result = try single(.repository(repositoryFacts("/work/api", submodules: true)))

    #expect(!result.isBlocked)
    let issue = try #require(result.issues.first { $0.kind == .submodules })
    #expect(issue.severity == .warning)
    #expect(
      issue.command
        == "git -C /wt/refonte-facturation/api submodule update --init --recursive")
  }

  @Test("The default branch as a base, when no remote names one, falls back to HEAD and says so")
  func defaultBranchUnknown() throws {
    let result = try single(.repository(repositoryFacts("/work/api")), base: .defaultBranch)

    #expect(result.action == .createWorktree(createsBranch: true))
    #expect(kinds(result) == [.defaultBranchUnknown])
    #expect(result.baseLabel == "main at 3f2a1c9")
  }

  @Test("The default branch as a base starts from what origin/HEAD points at")
  func defaultBranchKnown() throws {
    let origin = GitBranchReference(name: "origin/main", revision: "aaaaaaa1111")
    let result = try single(
      .repository(repositoryFacts("/work/api", branch: "feature", defaultBranch: origin)),
      base: .defaultBranch
    )

    #expect(result.baseRevision == "aaaaaaa1111")
    #expect(result.baseLabel == "origin/main at aaaaaaa")
  }

  // MARK: - Several repositories

  @Test("The same repository reached twice is held back the second time")
  func duplicate() {
    let first = SessionDraftRepository(path: "/work/api")
    let second = SessionDraftRepository(path: "/work/api-link")
    let common = "/work/api/.git"
    let result = plan([
      (first, .repository(repositoryFacts("/work/api", commonDirectory: common))),
      (second, .repository(repositoryFacts("/work/api-link", commonDirectory: common))),
    ])

    #expect(!result.repositories[0].isBlocked)
    #expect(result.repositories[1].blockingIssue?.kind == .duplicate)
  }

  @Test("Two repositories of the same name are told apart by their parent, then by a counter")
  func homonyms() {
    let paths = ["/work/api", "/legacy/api", "/other/legacy/api"]
    let result = plan(
      paths.map { path in
        (SessionDraftRepository(path: path), .repository(repositoryFacts(path)))
      })

    #expect(result.repositories.map(\.subfolderName) == ["api", "legacy-api", "legacy-api-2"])
  }

  @Test("One repository in conflict holds back only itself")
  func conflictIsLocal() {
    let result = plan([
      (SessionDraftRepository(path: "/work/api"), .repository(repositoryFacts("/work/api"))),
      (SessionDraftRepository(path: "/work/web"), .bare(commonDirectory: "/work/web.git")),
      (SessionDraftRepository(path: "/work/lib"), .repository(repositoryFacts("/work/lib"))),
    ])

    #expect(result.repositories.map(\.isBlocked) == [false, true, false])
    #expect(result.sessionIssues.isEmpty)
  }

  // MARK: - The slug

  @Test("A slug another session works under is a session problem, with a suffix proposed")
  func slugTakenBySession() {
    let result = plan(
      [(SessionDraftRepository(path: "/work/api"), .repository(repositoryFacts("/work/api")))],
      taken: ["refonte-facturation": "Billing"]
    )

    #expect(result.sessionIssues.map(\.field) == [.slug])
    #expect(result.sessionIssues[0].message.contains("Billing"))
    #expect(result.slugSuggestion?.rawValue == "refonte-facturation-2")
  }

  @Test("The suggestion skips the branches that already exist in the repositories")
  func suggestionSkipsBranches() {
    let branches: Set<String> = ["main", branch, branch + "-2"]
    let result = plan(
      [
        (
          SessionDraftRepository(path: "/work/api"),
          .repository(repositoryFacts("/work/api", branches: branches))
        )
      ]
    )

    #expect(result.slugSuggestion?.rawValue == "refonte-facturation-3")
    #expect(result.sessionIssues.isEmpty)
  }

  @Test("A free slug proposes nothing")
  func freeSlug() {
    let result = plan([
      (SessionDraftRepository(path: "/work/api"), .repository(repositoryFacts("/work/api")))
    ])

    #expect(result.slugSuggestion == nil)
    #expect(result.sessionFolderPath == "/wt/refonte-facturation")
  }
}

@Suite("Quoting a path for the shell")
struct ShellQuotingTests {
  @Test("A path with spaces, an apostrophe and parentheses pastes into a shell as it is")
  func difficultPath() {
    let quoted = ShellQuoting.quote("/Users/a/Mes Projets/l'API (v2)")

    #expect(quoted == "'/Users/a/Mes Projets/l'\\''API (v2)'")
  }

  @Test("A plain path is left alone")
  func plainPath() {
    #expect(ShellQuoting.quote("/usr/local/bin") == "/usr/local/bin")
    #expect(ShellQuoting.command(["git", "-C", "/a b"]) == "git -C '/a b'")
  }

  @Test("An empty argument is still an argument")
  func emptyArgument() {
    #expect(ShellQuoting.quote("") == "''")
  }
}
