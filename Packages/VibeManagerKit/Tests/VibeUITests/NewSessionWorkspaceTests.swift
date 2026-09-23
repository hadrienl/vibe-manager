import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("The repositories of the new session sheet")
struct NewSessionWorkspaceTests {
  private static let api = GitRepositoryFacts(
    topLevelPath: "/work/api",
    commonDirectory: "/work/api/.git",
    headRevision: "3f2a1c9d",
    branchName: "main"
  )

  private static let web = GitRepositoryFacts(
    topLevelPath: "/work/web",
    commonDirectory: "/work/web/.git",
    headRevision: "aa11bb22",
    branchName: "main",
    localBranches: ["main", "vibe/refonte"]
  )

  private func makeModel(inspector: SheetInspector) -> NewSessionModel {
    let registry = SheetRegistry()
    return NewSessionModel(
      create: CreateSession(
        repository: SheetRepository(),
        agents: registry,
        folders: SheetFolders(),
        workspace: SessionWorkspaceServices(
          inspector: inspector,
          writer: SheetWriter(),
          root: FixedWorktreeRoot(path: "/roots"),
          folders: SheetFolders()
        )
      ),
      registry: registry,
      revalidationDelay: .milliseconds(1)
    )
  }

  private func inspector() -> SheetInspector {
    SheetInspector(inspections: [
      "/work/api": .repository(Self.api),
      "/work/web": .repository(Self.web),
      "/work/notes": .plainFolder,
    ])
  }

  @Test("A designated folder is read once, and planned as a worktree under the session's folder")
  func designatedFolderIsPlanned() async throws {
    let reads = inspector()
    let model = makeModel(inspector: reads)
    await model.load(defaultWorkingDirectoryPath: nil)
    model.draft.name = "Refonte"

    await model.folderChosen("/work/api")
    await model.refreshPreview()

    let main = try #require(model.draft.repositories.first)
    let plan = try #require(model.plan(for: main.id))
    #expect(plan.action == .createWorktree(createsBranch: true))
    #expect(plan.worktreePath == "/roots/refonte/api")
    #expect(model.branchPreview == "vibe/refonte")
    #expect(await reads.count(of: "/work/api") == 1)
  }

  @Test("Typing a slug replans without reading any folder again")
  func slugTypingReadsNothing() async throws {
    let reads = inspector()
    let model = makeModel(inspector: reads)
    await model.load(defaultWorkingDirectoryPath: nil)
    model.draft.name = "Refonte"
    await model.folderChosen("/work/api")

    model.slugText = "billing"
    await model.refreshPreview()

    let main = try #require(model.draft.repositories.first)
    #expect(model.plan(for: main.id)?.worktreePath == "/roots/billing/api")
    #expect(!model.slugFollowsName)
    #expect(await reads.count(of: "/work/api") == 1)

    model.resetSlug()
    #expect(model.slugText == "refonte")
  }

  @Test("A conflict on one repository proposes its ways out, and picking one replans it")
  func resolutionReplans() async throws {
    let model = makeModel(inspector: inspector())
    await model.load(defaultWorkingDirectoryPath: nil)
    model.draft.name = "Refonte"
    await model.folderChosen("/work/api")
    await model.addRepository("/work/web")

    let web = try #require(model.draft.repositories.last)
    let blocked = try #require(model.plan(for: web.id))
    #expect(blocked.isBlocked)
    #expect(blocked.issues.first?.resolutions.contains(.useExistingBranch) == true)

    model.resolve(.useExistingBranch, for: web.id)
    await model.refreshPreview()

    #expect(model.plan(for: web.id)?.action == .createWorktree(createsBranch: false))
  }

  @Test("Changing the slug from a conflict renames the session's branch, not the repository")
  func changeSlugResolution() async throws {
    let model = makeModel(inspector: inspector())
    await model.load(defaultWorkingDirectoryPath: nil)
    model.draft.name = "Refonte"
    await model.folderChosen("/work/web")

    let web = try #require(model.draft.repositories.first)
    let effect = model.resolve(.changeSlug(suggestion: "refonte-2"), for: web.id)

    #expect(effect == .changeSlug("refonte-2"))
    #expect(model.draft.customSlug == "refonte-2")
  }

  @Test("The main repository is the first one, and moving another up makes it the main one")
  func reordering() async throws {
    let model = makeModel(inspector: inspector())
    await model.load(defaultWorkingDirectoryPath: nil)
    await model.folderChosen("/work/api")
    await model.addRepository("/work/notes")
    let notes = try #require(model.draft.repositories.last)

    model.moveRepository(notes.id, by: -1)

    #expect(model.draft.repositories.first?.id == notes.id)
    #expect(model.draft.workingDirectoryPath == "/work/notes")
  }

  @Test("The convention the agent will be sent is shown before anything is created")
  func conventionIsPreviewed() async throws {
    let model = makeModel(inspector: inspector())
    await model.load(defaultWorkingDirectoryPath: nil)
    model.draft.name = "Refonte"
    await model.folderChosen("/work/api")
    await model.addRepository("/work/notes")
    await model.refreshPreview()

    let convention = try #require(model.preview?.convention)
    #expect(convention.contains("vibe/refonte"))
    #expect(convention.contains("/roots/refonte/api"))
    #expect(convention.contains("/work/notes"))
  }

  @Test("Removing a repository forgets what was read of it")
  func removal() async throws {
    let model = makeModel(inspector: inspector())
    await model.load(defaultWorkingDirectoryPath: nil)
    await model.folderChosen("/work/api")
    await model.addRepository("/work/notes")
    let notes = try #require(model.draft.repositories.last)

    model.removeRepository(notes.id)

    #expect(model.draft.repositories.count == 1)
    #expect(model.inspections[notes.id] == nil)
  }
}

// MARK: - Doubles

private actor SheetInspector: RepositoryInspecting {
  private let inspections: [String: RepositoryInspection]
  private var reads: [String: Int] = [:]

  init(inspections: [String: RepositoryInspection]) {
    self.inspections = inspections
  }

  func inspect(path: String) -> RepositoryInspection {
    reads[path, default: 0] += 1
    return inspections[path] ?? .unusable(.missing)
  }

  func count(of path: String) -> Int { reads[path] ?? 0 }
}

private struct SheetWriter: WorktreeCreating {
  func createSessionFolder(atPath path: String) async throws {}
  func createWorktree(_ request: WorktreeCreationRequest) async throws {}
  func createBranchInPlace(repositoryPath: String, commonDirectory: String, branch: String)
    async throws
  {}
}

/// Nothing exists where a worktree would go, and every designated folder can be entered.
private struct SheetFolders: WorkingDirectoryProbe {
  func inspect(path: String) async -> WorkingDirectoryStatus {
    path.hasPrefix("/roots") ? .missing : .usable
  }
}

private actor SheetRepository: SessionRepository {
  private var stored: [WorkSession] = []

  func sessions() -> [WorkSession] { stored }
  func session(id: SessionID) -> WorkSession? { stored.first { $0.id == id } }
  func save(_ session: WorkSession) {
    stored.removeAll { $0.id == session.id }
    stored.append(session)
  }
}

private struct SheetProvider: AgentProvider {
  let descriptor = AgentDescriptor(
    id: AgentProviderID("claude-code"),
    displayName: "Claude Code",
    capabilities: AgentCapabilities(
      supportsInitialPrompt: true, supportsAdditionalDirectories: true)
  )

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentAvailability(
      state: .available,
      installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id,
        providerName: descriptor.displayName,
        state: .available,
        summary: "Ready.",
        probedAt: Date(timeIntervalSince1970: 0),
        remediations: []
      )
    )
  }

  func models() async -> [AgentModel] { [] }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: descriptor.id,
      executablePath: "/usr/bin/true",
      arguments: [],
      environment: request.additionalEnvironment,
      workingDirectoryPath: request.workingDirectoryPath,
      promptDelivery: request.initialPrompt == nil ? .none : .argument
    )
  }
}

private struct SheetRegistry: AgentProviderResolving {
  func descriptors() async -> [AgentDescriptor] { [SheetProvider().descriptor] }
  func provider(id: AgentProviderID) async -> (any AgentProvider)? { SheetProvider() }
  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
    [SheetProvider().descriptor.id: await SheetProvider().availability(forceRefresh: false)]
  }
}
