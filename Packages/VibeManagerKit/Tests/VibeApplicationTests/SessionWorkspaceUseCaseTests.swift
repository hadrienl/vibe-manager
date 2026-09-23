import Foundation
import Testing
import VibeApplication
import VibeDomain

private let later = Date(timeIntervalSince1970: 1_800_000_000)

private func worktreePlan(_ name: String, blocked: Bool = false) -> RepositoryPlan {
  RepositoryPlan(
    id: RepositoryID(),
    designatedPath: "/work/\(name)",
    rootPath: "/work/\(name)",
    mode: .worktree,
    action: blocked ? .blocked : .createWorktree(createsBranch: true),
    worktreePath: "/wt/s/\(name)",
    subfolderName: name,
    branchName: "vibe/s",
    baseRevision: "abc",
    commonDirectory: "/work/\(name)/.git",
    createdByVibeManager: true,
    issues: blocked ? [.init(kind: .bare, severity: .blocking, message: "Bare.", remedy: "…")] : []
  )
}

private func workspacePlan(_ repositories: [RepositoryPlan]) -> SessionWorkspacePlan {
  SessionWorkspacePlan(slug: slug("s"), sessionFolderPath: "/wt/s", repositories: repositories)
}

@Suite("Preparing the repositories of a session")
struct PrepareSessionWorkspaceTests {
  @Test("A repository that fails leaves the others prepared, in their order")
  func partialFailure() async {
    let writer = WorkspaceWriter(failingPaths: ["/wt/s/web"])
    let prepared = await PrepareSessionWorkspace(writer: writer)(
      workspacePlan([worktreePlan("api"), worktreePlan("web"), worktreePlan("lib")]),
      attachedAt: later
    )

    #expect(prepared.map(\.displayName) == ["api", "web", "lib"])
    #expect(prepared.map { $0.failure == nil } == [true, false, true])
    #expect(prepared[0].worktreePath == "/wt/s/api")
    #expect(prepared[1].worktreePath == nil)
    #expect(prepared[1].failure?.message.contains("refused by the test") == true)
    #expect(prepared[2].createdByVibeManager)
  }

  @Test("The session folder is created once, before the first worktree")
  func folderOnce() async {
    let writer = WorkspaceWriter()
    _ = await PrepareSessionWorkspace(writer: writer)(
      workspacePlan([worktreePlan("api"), worktreePlan("web")]), attachedAt: later)

    #expect(
      await writer.calls == ["folder /wt/s", "worktree /wt/s/api", "worktree /wt/s/web"])
  }

  @Test("A blocked repository is attached with its conflict, and nothing is written for it")
  func blockedWritesNothing() async {
    let writer = WorkspaceWriter()
    let prepared = await PrepareSessionWorkspace(writer: writer)(
      workspacePlan([worktreePlan("api", blocked: true)]), attachedAt: later)

    #expect(await writer.calls.isEmpty)
    #expect(prepared[0].failure?.message == "Bare.")
  }

  @Test("Cancelling stops between two repositories, and the rest is attached as cancelled")
  func cancellation() async {
    let writer = WorkspaceWriter(cancelsOnFirstWorktree: true)
    let prepared = await Task {
      await PrepareSessionWorkspace(writer: writer)(
        workspacePlan([worktreePlan("api"), worktreePlan("web"), worktreePlan("lib")]),
        attachedAt: later
      )
    }.value

    #expect(await writer.requests.map(\.worktreePath) == ["/wt/s/api"])
    #expect(prepared[0].failure == nil)
    #expect(prepared[1].failure?.message == prepared[2].failure?.message)
    #expect(prepared[1].failure?.message.contains("cancelled") == true)
  }
}

@Suite("Creating a session across several repositories")
struct CreateSessionWorkspaceTests {
  private let paths = ["/work/api", "/work/web", "/work/lib"]

  private func draft(name: String = "Refonte facturation", paths: [String]? = nil)
    -> SessionDraft
  {
    SessionDraft(
      name: name,
      initialPrompt: "Split the invoice builder.",
      providerID: "stub",
      repositories: (paths ?? self.paths).map { SessionDraftRepository(path: $0) }
    )
  }

  private func makeSubject(
    inspections: [String: RepositoryInspection]? = nil,
    writer: WorkspaceWriter = WorkspaceWriter(),
    sessions: [WorkSession] = []
  ) -> (CreateSession, RestorationRepository, RequestLog, WorkspaceInspector) {
    let answers =
      inspections
      ?? Dictionary(uniqueKeysWithValues: paths.map { ($0, .repository(repositoryFacts($0))) })
    let inspector = WorkspaceInspector(answers)
    let log = RequestLog()
    let repository = RestorationRepository(sessions: sessions)
    let create = CreateSession(
      repository: repository,
      agents: RecordingRegistry(provider: RecordingProvider(log: log)),
      folders: WorkspaceFolders(),
      clock: RestorationClock(later),
      workspace: workspaceServices(inspector: inspector, writer: writer)
    )
    return (create, repository, log, inspector)
  }

  @Test("One repository in conflict: the session exists, the others are prepared, the agent starts")
  func partialConflict() async throws {
    var answers = Dictionary(
      uniqueKeysWithValues: paths.map { ($0, RepositoryInspection.repository(repositoryFacts($0))) }
    )
    answers["/work/web"] = .repository(
      repositoryFacts("/work/web", branches: ["main", "vibe/refonte-facturation"]))
    let (create, repository, log, _) = makeSubject(inspections: answers)

    let creation = try await create(draft())

    let stored = try #require(await repository.sessions().first)
    #expect(stored.repositories.count == 3)
    #expect(stored.repositories.map { $0.failure == nil } == [true, false, true])
    #expect(creation.plan?.workingDirectoryPath == "/wt/refonte-facturation/api")
    let request = try #require(await log.last)
    #expect(request.additionalWorkingDirectoryPaths == ["/wt/refonte-facturation/lib"])
    #expect(request.initialPrompt?.hasPrefix("Vibe Manager runs this session") == true)
    #expect(request.initialPrompt?.hasSuffix("Split the invoice builder.") == true)
  }

  @Test("A main repository that cannot be prepared holds the session back")
  func mainBlocked() async {
    var answers = Dictionary(
      uniqueKeysWithValues: paths.map { ($0, RepositoryInspection.repository(repositoryFacts($0))) }
    )
    answers["/work/api"] = .bare(commonDirectory: "/work/api.git")
    let (create, repository, _, _) = makeSubject(inspections: answers)

    await #expect {
      try await create(draft())
    } throws: { error in
      (error as? SessionCreationRejected)?.issues.contains(.mainRepositoryBlocked) == true
    }
    #expect(await repository.sessions().isEmpty)
  }

  @Test("A main repository that fails while being prepared: stored, and not launched")
  func mainFailsDuringPreparation() async throws {
    let writer = WorkspaceWriter(failingPaths: ["/wt/refonte-facturation/api"])
    let (create, repository, _, _) = makeSubject(writer: writer)

    let creation = try await create(draft())

    #expect(creation.plan == nil)
    guard case .mainRepositoryUnprepared(let name, _) = creation.launchRefusal else {
      Issue.record("Expected the main repository to be reported unprepared")
      return
    }
    #expect(name == "api")
    #expect(await repository.sessions().count == 1)
  }

  @Test("The slug is stored, and renaming the session does not change it")
  func slugIsStable() async throws {
    let (create, repository, _, _) = makeSubject()

    let creation = try await create(draft())
    _ = try await repository.mutate(id: creation.session.id) { $0.name = "Something else" }

    let stored = try #require(await repository.session(id: creation.session.id))
    #expect(stored.slug?.rawValue == "refonte-facturation")
    #expect(stored.repositories[0].branchName == "vibe/refonte-facturation")
  }

  @Test("A slug another session still works under is refused on the slug field")
  func slugTaken() async {
    let other = WorkSession(
      name: "Billing", repositories: [RepositoryContext(rootPath: "/work/x")],
      slug: slug("refonte-facturation"))
    let (create, _, _, _) = makeSubject(sessions: [other])

    await #expect {
      try await create(draft())
    } throws: { error in
      (error as? SessionCreationRejected)?.issues.contains { $0.field == .slug } == true
    }
  }

  @Test("A preview reads no folder: it plans from what was already read")
  func previewReadsNothing() async {
    let (create, _, _, inspector) = makeSubject()
    let subject = draft()

    let unread = await create.preview(subject, inspections: [:])
    var known: [RepositoryID: RepositoryInspection] = [:]
    for repository in subject.repositories {
      known[repository.id] = .repository(repositoryFacts(repository.path))
    }
    let read = await create.preview(subject, inspections: known)

    #expect(unread.workspace == nil)
    #expect(read.workspace?.repositories.count == 3)
    #expect(read.convention?.contains("across 3 repositories") == true)
    #expect(await inspector.calls.isEmpty)
  }
}

@Suite("Restarting a session across several repositories")
struct RestartSessionWorkspaceTests {
  private func repository(_ name: String) -> RepositoryContext {
    RepositoryContext(
      rootPath: "/work/\(name)", mode: .worktree, worktreePath: "/wt/s/\(name)",
      branchName: "vibe/s", createdByVibeManager: true)
  }

  private func session(_ repositories: [RepositoryContext], started: Bool = true) -> WorkSession {
    let created = Date(timeIntervalSince1970: 1_699_000_000)
    return WorkSession(
      name: "S",
      initialPrompt: "Do the thing.",
      agent: SessionAgentConfiguration(providerID: "stub"),
      status: .closed,
      createdAt: created,
      updatedAt: started ? Date(timeIntervalSince1970: 1_700_000_000) : created,
      closedAt: started ? Date(timeIntervalSince1970: 1_700_000_000) : created,
      repositories: repositories,
      slug: slug("s")
    )
  }

  private func restart(
    _ session: WorkSession,
    missing: Set<String> = [],
    branches: [String: String] = [:]
  ) async throws -> (SessionRestart, AgentLaunchRequest?) {
    let inspector = WorkspaceInspector()
    for repository in session.repositories {
      guard let path = repository.worktreePath else { continue }
      await inspector.set(
        path, .repository(repositoryFacts(path, branch: branches[path] ?? "vibe/s")))
    }
    let log = RequestLog()
    let restart = RestartSession(
      repository: RestorationRepository(sessions: [session]),
      agents: RecordingRegistry(provider: RecordingProvider(log: log)),
      folders: RestartFolders(missing: missing),
      workspace: workspaceServices(inspector: inspector)
    )
    let outcome = try await restart(id: session.id)
    return (outcome, await log.last)
  }

  @Test("A main worktree that disappeared refuses the launch, with its path")
  func mainWorktreeMissing() async {
    await #expect(
      throws: SessionRestartRefusal.mainWorktreeMissing(name: "api", path: "/wt/s/api")
    ) {
      try await self.restart(
        self.session([self.repository("api"), self.repository("web")]), missing: ["/wt/s/api"])
    }
  }

  @Test("A secondary worktree that disappeared is left out, and said")
  func secondaryMissing() async throws {
    let (outcome, request) = try await restart(
      session([repository("api"), repository("web")]), missing: ["/wt/s/web"])

    #expect(outcome.plan.workingDirectoryPath == "/wt/s/api")
    #expect(request?.additionalWorkingDirectoryPaths == [])
    #expect(outcome.warnings.contains { $0.contains("web") && $0.contains("without it") })
  }

  @Test("A worktree on another branch starts as it is, with a warning naming that branch")
  func otherBranch() async throws {
    let (outcome, _) = try await restart(
      session([repository("api")]), branches: ["/wt/s/api": "experiment"])

    #expect(outcome.plan.workingDirectoryPath == "/wt/s/api")
    #expect(outcome.warnings == ["api is on experiment, not vibe/s."])
  }

  @Test("A clone attached in place that disappeared is refused as it always was")
  func inPlaceCloneMissing() async {
    let clone = RepositoryContext(rootPath: "/work/app", mode: .inPlace)
    await #expect(
      throws: SessionRestartRefusal.workingDirectoryUnusable(path: "/work/app", status: .missing)
    ) {
      try await self.restart(self.session([clone]), missing: ["/work/app"])
    }
  }

  @Test("A first launch hands over the convention, then the initial prompt")
  func firstLaunch() async throws {
    let (outcome, request) = try await restart(
      session([repository("api"), repository("web")], started: false))

    #expect(outcome.mode == .firstLaunch)
    #expect(request?.initialPrompt?.hasPrefix("Vibe Manager runs this session") == true)
    #expect(request?.initialPrompt?.hasSuffix("Do the thing.") == true)
    #expect(request?.additionalWorkingDirectoryPaths == ["/wt/s/web"])
  }
}

/// A disk where only the listed paths are missing — worktrees included.
private struct RestartFolders: WorkingDirectoryProbe {
  let missing: Set<String>

  func inspect(path: String) async -> WorkingDirectoryStatus {
    missing.contains(path) ? .missing : .usable
  }
}

@Suite("Changing the repositories of an existing session")
struct SessionRepositoryEditingTests {
  private func stored(
    _ repositories: [RepositoryContext],
    slug: SessionSlug? = nil,
    name: String = "Legacy work"
  ) -> WorkSession {
    WorkSession(
      name: name,
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      closedAt: Date(timeIntervalSince1970: 1_700_000_000),
      repositories: repositories,
      slug: slug
    )
  }

  private func services(
    _ paths: [String],
    writer: WorkspaceWriter = WorkspaceWriter(),
    branches: Set<String> = ["main"]
  ) -> SessionWorkspaceServices {
    let inspector = WorkspaceInspector(
      Dictionary(
        uniqueKeysWithValues: paths.map {
          ($0, RepositoryInspection.repository(repositoryFacts($0, branches: branches)))
        }))
    return workspaceServices(inspector: inspector, writer: writer)
  }

  @Test("A session stored without a slug is given one at its first worktree, and keeps it")
  func legacySlug() async throws {
    let session = stored([RepositoryContext(rootPath: "/work/app")])
    let repository = RestorationRepository(sessions: [session])
    let attach = AttachRepository(
      repository: repository, services: services(["/work/api", "/work/web"]),
      clock: RestorationClock(later))

    let first = try await attach(
      sessionID: session.id, adding: SessionDraftRepository(path: "/work/api"), isRunning: false)
    _ = try await repository.mutate(id: session.id) { $0.name = "Renamed" }
    let second = try await attach(
      sessionID: session.id, adding: SessionDraftRepository(path: "/work/web"), isRunning: false)

    #expect(first.session.slug?.rawValue == "legacy-work")
    #expect(second.session.slug?.rawValue == "legacy-work")
    #expect(second.repository.worktreePath == "/wt/legacy-work/web")
    #expect(first.addendum == nil)
  }

  @Test("A repository added to a running session comes with an addendum to send")
  func addendumWhenRunning() async throws {
    let session = stored([RepositoryContext(rootPath: "/work/app")], slug: slug("s"))
    let attach = AttachRepository(
      repository: RestorationRepository(sessions: [session]), services: services(["/work/api"]),
      clock: RestorationClock(later))

    let attachment = try await attach(
      sessionID: session.id, adding: SessionDraftRepository(path: "/work/api"), isRunning: true)

    #expect(attachment.addendum?.contains("/wt/s/api") == true)
    #expect(attachment.session.repositories.count == 2)
  }

  @Test("Detaching forgets, writes nothing, and hands back the command to copy")
  func detach() async throws {
    let main = RepositoryContext(
      rootPath: "/work/Mes Projets/l'API", mode: .worktree, worktreePath: "/wt/s/api",
      branchName: "vibe/s", createdByVibeManager: true)
    let other = RepositoryContext(rootPath: "/work/web")
    let session = stored([main, other], slug: slug("s"))
    let detach = DetachRepository(
      repository: RestorationRepository(sessions: [session]), clock: RestorationClock(later))

    let detachment = try await detach(sessionID: session.id, repositoryID: main.id)

    #expect(detachment.changedMainRepository)
    #expect(detachment.session.repositories.map(\.id) == [other.id])
    #expect(
      detachment.cleanupCommand
        == "git -C '/work/Mes Projets/l'\\''API' worktree remove /wt/s/api && "
        + "git -C '/work/Mes Projets/l'\\''API' branch -d vibe/s")
  }

  @Test("An adopted worktree's cleanup warns first, and leaves its branch alone")
  func adoptedCleanup() {
    let adopted = RepositoryContext(
      rootPath: "/work/api", mode: .worktree, worktreePath: "/work/api-other",
      branchName: "vibe/s", createdByVibeManager: false)

    let command = RepositoryCleanupCommand.make(for: adopted)

    #expect(command?.hasPrefix("# This worktree existed before the session") == true)
    #expect(command?.contains("branch -d") == false)
  }

  @Test("The last repository cannot be detached")
  func lastRepository() async {
    let only = RepositoryContext(rootPath: "/work/app")
    let session = stored([only])
    let detach = DetachRepository(
      repository: RestorationRepository(sessions: [session]), clock: RestorationClock(later))

    await #expect(throws: SessionWorkspaceError.lastRepository) {
      try await detach(sessionID: session.id, repositoryID: only.id)
    }
  }

  @Test("Making a repository the main one moves it to the top")
  func makeMain() async throws {
    let first = RepositoryContext(rootPath: "/work/app")
    let second = RepositoryContext(rootPath: "/work/web")
    let session = stored([first, second])
    let make = MakeMainRepository(
      repository: RestorationRepository(sessions: [session]), clock: RestorationClock(later))

    let updated = try await make(sessionID: session.id, repositoryID: second.id)

    #expect(updated.repositories.map(\.id) == [second.id, first.id])
  }

  @Test("Recreating a worktree puts it back on the session's existing branch, in its folder")
  func repair() async throws {
    let gone = RepositoryContext(
      rootPath: "/work/api", mode: .worktree, worktreePath: "/wt/s/api",
      branchName: "vibe/s", createdByVibeManager: true)
    let session = stored([gone], slug: slug("s"))
    let writer = WorkspaceWriter()
    let repair = RepairRepository(
      repository: RestorationRepository(sessions: [session]),
      services: services(["/work/api"], writer: writer, branches: ["main", "vibe/s"]),
      clock: RestorationClock(later)
    )

    let repaired = try await repair(sessionID: session.id, repositoryID: gone.id)

    #expect(repaired.failure == nil)
    #expect(repaired.worktreePath == "/wt/s/api")
    let request = try #require(await writer.requests.first)
    #expect(!request.createsBranch)
    #expect(request.branchName == "vibe/s")
  }
}
