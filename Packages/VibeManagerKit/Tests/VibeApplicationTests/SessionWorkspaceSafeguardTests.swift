import Foundation
import Testing
import VibeApplication
import VibeDomain

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("What the workspace refuses to do quietly")
struct SessionWorkspaceSafeguardTests {
  private func create(
    inspector: WorkspaceInspector,
    writer: WorkspaceWriter = WorkspaceWriter(),
    repository: RestorationRepository
  ) -> CreateSession {
    CreateSession(
      repository: repository,
      agents: RecordingRegistry(provider: RecordingProvider()),
      folders: WorkspaceFolders(),
      clock: RestorationClock(now),
      workspace: workspaceServices(inspector: inspector, writer: writer)
    )
  }

  private func draft(_ name: String, _ repositories: [SessionDraftRepository]) -> SessionDraft {
    SessionDraft(name: name, providerID: "stub", repositories: repositories)
  }

  @Test("Two sessions of the same name share nothing when neither names a branch")
  func sameTitleWithoutBranch() async throws {
    let inspector = WorkspaceInspector([
      "/work/notes": .plainFolder,
      "/work/api": .repository(repositoryFacts("/work/api")),
    ])
    let repository = RestorationRepository(sessions: [])
    let subject = create(inspector: inspector, repository: repository)

    let first = try await subject(draft("Review", [SessionDraftRepository(path: "/work/notes")]))
    let second = try await subject(
      draft("Review", [SessionDraftRepository(path: "/work/api", mode: .inPlace)]))

    #expect(first.session.slug == nil)
    #expect(second.session.slug == nil)
    #expect(await repository.sessions().count == 2)
  }

  @Test("A slug Git would refuse only matters when a worktree would carry it")
  func invalidSlugWithoutBranch() async throws {
    let inspector = WorkspaceInspector(["/work/notes": .plainFolder])
    var notes = draft("Notes", [SessionDraftRepository(path: "/work/notes")])
    notes.customSlug = "not a slug"

    let creation = try await create(
      inspector: inspector, repository: RestorationRepository(sessions: [])
    )(notes)

    #expect(creation.session.slug == nil)
  }

  @Test("A plan that changed since it was shown is not carried out")
  func planChangedIsRefused() async throws {
    let inspector = WorkspaceInspector([
      "/work/api": .repository(repositoryFacts("/work/api")),
      "/work/web": .repository(repositoryFacts("/work/web")),
    ])
    let writer = WorkspaceWriter()
    let repository = RestorationRepository(sessions: [])
    let subject = create(inspector: inspector, writer: writer, repository: repository)
    let api = SessionDraftRepository(path: "/work/api")
    let web = SessionDraftRepository(path: "/work/web")
    let shown = draft("Refonte", [api, web])
    let preview = await subject.preview(
      shown,
      inspections: [
        api.id: .repository(repositoryFacts("/work/api")),
        web.id: .repository(repositoryFacts("/work/web")),
      ])

    // Between the plan and Create, someone checks the session's branch out elsewhere.
    await inspector.set(
      "/work/web",
      .repository(
        repositoryFacts(
          "/work/web",
          branches: ["main", "vibe/refonte"],
          worktrees: [GitWorktreeRecord(path: "/elsewhere", branchName: "vibe/refonte")]
        )))

    await #expect(throws: SessionCreationRejected(issues: [.planChanged])) {
      try await subject(shown, expecting: preview.workspace)
    }
    #expect(await writer.calls.isEmpty)
    #expect(await repository.sessions().isEmpty)
  }

  @Test("A repair that fails keeps the worktree's path, its base and whose it was")
  func failedRepairKeepsTheRecord() async throws {
    let stored = RepositoryContext(
      rootPath: "/work/api",
      mode: .worktree,
      worktreePath: "\(workspaceRoot)/refonte/api",
      branchName: "vibe/refonte",
      baseRevision: "3f2a1c9",
      createdByVibeManager: true,
      attachedAt: now
    )
    let session = WorkSession(
      name: "Refonte",
      createdAt: now,
      updatedAt: now,
      closedAt: now,
      repositories: [stored],
      slug: slug("refonte")
    )
    let repository = RestorationRepository(sessions: [session])
    // The folder was deleted by hand; Git still has it on record.
    let inspector = WorkspaceInspector([
      "/work/api": .repository(
        repositoryFacts(
          "/work/api",
          branches: ["main", "vibe/refonte"],
          worktrees: [
            GitWorktreeRecord(
              path: "\(workspaceRoot)/refonte/api", branchName: "vibe/refonte", isPrunable: true)
          ]
        ))
    ])
    let writer = WorkspaceWriter()

    let repaired = try await RepairRepository(
      repository: repository,
      services: workspaceServices(inspector: inspector, writer: writer),
      clock: RestorationClock(now)
    )(sessionID: session.id, repositoryID: stored.id)

    #expect(repaired.failure != nil)
    #expect(repaired.worktreePath == stored.worktreePath)
    #expect(repaired.baseRevision == "3f2a1c9")
    #expect(repaired.createdByVibeManager)
    #expect(RepositoryCleanupCommand.make(for: repaired)?.contains("branch -d") == true)
    #expect(await writer.calls.isEmpty)
  }

  @Test("A repository left out of a launch is told to the agent as a place not to work in")
  func missingRepositoryInTheConvention() throws {
    let web = RepositoryContext(
      rootPath: "/work/web", mode: .worktree, worktreePath: "/wt/refonte/web",
      branchName: "vibe/refonte", createdByVibeManager: true)
    let session = WorkSession(
      name: "Refonte",
      repositories: [
        RepositoryContext(
          rootPath: "/work/api", mode: .worktree, worktreePath: "/wt/refonte/api",
          branchName: "vibe/refonte", createdByVibeManager: true),
        web,
      ],
      slug: slug("refonte")
    )

    let context = try SessionLaunchContext.make(
      for: session, worktreeRootPath: "/moved", excluding: [web.id])
    let convention = try #require(context.convention)

    #expect(context.additionalWorkingDirectoryPaths.isEmpty)
    #expect(convention.contains("- /work/web\n  missing from the disk right now"))
    #expect(!convention.contains("/wt/refonte/web"))
    // The worktrees are under the old root; the setting moved since, and they did not.
    #expect(context.environment[SessionLaunchContext.rootVariable] == "/wt/refonte")
  }
}
