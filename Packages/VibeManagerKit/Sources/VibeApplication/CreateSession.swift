import Foundation
import VibeDomain

public struct SessionCreation: Sendable {
  public let session: WorkSession
  /// The plan the caller must launch — the very one whose problems were just checked, and, for
  /// Claude Code, the one carrying the session identifier the conversation will be named with.
  ///
  /// `nil` when the main repository could not be prepared after all. The session is stored with
  /// what happened to it, and `launchRefusal` says why nothing is started.
  public let plan: AgentLaunchPlan?
  public let launchRefusal: SessionRestartRefusal?

  public init(
    session: WorkSession,
    plan: AgentLaunchPlan?,
    launchRefusal: SessionRestartRefusal? = nil
  ) {
    self.session = session
    self.plan = plan
    self.launchRefusal = launchRefusal
  }
}

public struct SessionCreationRejected: Error, Equatable, Sendable {
  public let issues: [SessionDraftIssue]

  public init(issues: [SessionDraftIssue]) {
    self.issues = issues
  }
}

/// What the sheet shows before anything exists: the problems, the plan and the convention.
public struct SessionCreationPreview: Sendable {
  public let issues: [SessionDraftIssue]
  /// `nil` in a workspace without Git, and until the folders have been read.
  public let workspace: SessionWorkspacePlan?
  /// The block that will open the prompt, exactly as it will be sent. `nil` when there is
  /// nothing to coordinate.
  public let convention: String?
  public let plan: AgentLaunchPlan?
  /// The agent cannot be handed the session's other repositories.
  public let additionalDirectoriesUnsupported: Bool

  public init(
    issues: [SessionDraftIssue],
    workspace: SessionWorkspacePlan? = nil,
    convention: String? = nil,
    plan: AgentLaunchPlan? = nil,
    additionalDirectoriesUnsupported: Bool = false
  ) {
    self.issues = issues
    self.workspace = workspace
    self.convention = convention
    self.plan = plan
    self.additionalDirectoriesUnsupported = additionalDirectoriesUnsupported
  }
}

/// Turns a whole draft into a stored session, or into the list of reasons it cannot be one.
///
/// Nothing is written before every check has passed, so a rejected creation leaves the store
/// exactly as it was. The agent is asked for a launch plan as part of validation — building one
/// has no side effect, so the same call previews the command line and proves the prompt fits.
public struct CreateSession: Sendable {
  private let repository: any SessionRepository
  private let agents: any AgentProviderResolving
  private let folders: any WorkingDirectoryProbe
  private let clock: any SessionClock
  private let workspace: SessionWorkspaceServices?

  /// - Parameter workspace: Git and the worktree root. Without it every folder is attached in
  ///   place, exactly as a session was before worktrees existed.
  public init(
    repository: any SessionRepository,
    agents: any AgentProviderResolving,
    folders: any WorkingDirectoryProbe = FileManagerWorkingDirectoryProbe(),
    clock: any SessionClock = SystemSessionClock(),
    workspace: SessionWorkspaceServices? = nil
  ) {
    self.repository = repository
    self.agents = agents
    self.folders = folders
    self.clock = clock
    self.workspace = workspace
  }

  /// Whether folders are planned — read by Git, given worktrees — or attached as they are.
  public var plansWorkspace: Bool { workspace != nil }

  /// Reads one designated folder, for the sheet to plan with. The only disk access outside
  /// creation, made where the user designates a folder through the open panel.
  public func inspect(_ repository: SessionDraftRepository) async -> RepositoryInspection {
    if let workspace { return await workspace.plan.inspect(repository) }
    guard let path = repository.resolvedPath, path.hasPrefix("/") else {
      return .unusable(.missing)
    }
    let status = await folders.inspect(path: path)
    return status == .usable ? .plainFolder : .unusable(status)
  }

  /// The problems, the plan and the convention of a draft, from folders already read.
  ///
  /// A folder missing from `inspections` has not been read yet and is not read here: typing is
  /// not a request to open anything.
  public func preview(
    _ draft: SessionDraft,
    inspections: [RepositoryID: RepositoryInspection]
  ) async -> SessionCreationPreview {
    await evaluate(draft, inspections: inspections, readingMissing: false)
  }

  /// Everything wrong with this draft right now, without creating anything.
  ///
  /// The working folder is only opened when `checkingFolder` is asked for, and the default is to
  /// leave it alone. Typing a path is not a request to read it: on a Mac, opening `~/Documents`
  /// raises a system consent alert, and doing that on every keystroke put the alert in the middle
  /// of the form. The folder is checked where the user actually designates one — at the return of
  /// the open panel, and at creation.
  ///
  /// - Parameter inspections: folders already read. With Git, those are used as they are and only
  ///   the others are read, so re-checking a form never runs Git again on a folder it has seen.
  public func problems(
    with draft: SessionDraft,
    checkingFolder: Bool = false,
    inspections: [RepositoryID: RepositoryInspection] = [:]
  ) async -> [SessionDraftIssue] {
    await evaluate(draft, inspections: inspections, readingMissing: checkingFolder).issues
  }

  /// - Parameter expected: the plan the user was shown. Reading the folders again gives the plan
  ///   that is carried out; when it would do something else, nothing is done and the user is sent
  ///   back to read it — preparing what was never shown is the one thing the plan exists to avoid.
  public func callAsFunction(
    _ draft: SessionDraft,
    expecting expected: SessionWorkspacePlan? = nil
  ) async throws -> SessionCreation {
    // Re-checked here rather than trusted from the sheet: a CLI can be uninstalled, and a folder
    // deleted, between the moment the form was filled and the moment Create is pressed. Every
    // folder is read again, so the preparation meets nothing the plan did not announce.
    let outcome = await evaluate(draft, inspections: [:], readingMissing: true)
    guard outcome.issues.isEmpty, let plan = outcome.plan else {
      throw SessionCreationRejected(issues: outcome.issues)
    }

    let createdAt = clock.now()
    guard let workspace, let workspacePlan = outcome.workspace else {
      let session = draft.session(createdAt: createdAt)
      try await repository.save(session)
      return SessionCreation(session: session, plan: plan)
    }

    if let expected, Self.actions(of: expected) != Self.actions(of: workspacePlan) {
      throw SessionCreationRejected(issues: [.planChanged])
    }

    // Prepared before the session is stored. A crash in between leaves worktrees and no session;
    // creating it again finds them, and offers to work in them rather than making them twice.
    let repositories = await workspace.prepare(workspacePlan, attachedAt: createdAt)
    let session = draft.session(
      createdAt: createdAt,
      repositories: repositories,
      slug: workspacePlan.usesSessionBranch ? draft.slug : nil
    )
    try await repository.save(session)

    // The plan previewed was built on the paths the preparation was about to create. It is built
    // again from what was actually prepared: a repository that failed after all is left out, and
    // a main repository that failed means there is nothing to start in.
    do {
      let launched = try await launchPlan(for: session, draft: draft, root: workspace.root)
      return SessionCreation(session: session, plan: launched)
    } catch let refusal as SessionRestartRefusal {
      return SessionCreation(session: session, plan: nil, launchRefusal: refusal)
    }
  }

  private static func actions(of plan: SessionWorkspacePlan) -> [RepositoryID: String] {
    Dictionary(
      uniqueKeysWithValues: plan.repositories.map {
        ($0.id, "\($0.action)|\($0.worktreePath ?? "")|\($0.branchName ?? "")")
      })
  }

  private func launchPlan(
    for session: WorkSession,
    draft: SessionDraft,
    root: any WorktreeRootProviding
  ) async throws -> AgentLaunchPlan {
    guard let providerID = draft.providerID,
      let provider = await agents.provider(id: AgentProviderID(providerID))
    else {
      throw SessionRestartRefusal.agentUnknown(draft.providerID ?? "")
    }
    let context: SessionLaunchContext
    do {
      context = try SessionLaunchContext.make(
        for: session, worktreeRootPath: await root.worktreeRootPath())
    } catch .noRepository {
      throw SessionRestartRefusal.noRepository
    } catch .mainRepositoryUnavailable(let main) {
      throw SessionRestartRefusal.mainRepositoryUnprepared(
        name: main.displayName,
        reason: main.failure?.message ?? "It could not be prepared."
      )
    }
    let userPrompt = draft.trimmedPrompt.isEmpty ? nil : draft.initialPrompt
    // An agent that takes no prompt at all is not handed the convention either: it would refuse
    // the launch over a text the user never wrote.
    let prompt =
      provider.descriptor.capabilities.supportsInitialPrompt
      ? context.prompt(with: userPrompt) : userPrompt
    do {
      return try await provider.launchPlan(
        for: context.request(modelID: draft.modelID, prompt: prompt))
    } catch let error as AgentLaunchError {
      throw SessionRestartRefusal.launchRejected(error)
    }
  }

  /// The draft's problems, each stated once.
  ///
  /// Two checks can reach the same conclusion — a relative folder is caught by the draft and
  /// again by the agent refusing to plan a launch — and an issue is identified by its field and
  /// its sentence, so a repeat would collide in the lists the sheet renders and would be counted
  /// twice in its footer.
  private func evaluate(
    _ draft: SessionDraft,
    inspections: [RepositoryID: RepositoryInspection],
    readingMissing: Bool
  ) async -> SessionCreationPreview {
    let outcome = await assess(draft, inspections: inspections, readingMissing: readingMissing)
    var seen: Set<SessionDraftIssue.ID> = []
    return SessionCreationPreview(
      issues: outcome.issues.filter { seen.insert($0.id).inserted },
      workspace: outcome.workspace,
      convention: outcome.convention,
      plan: outcome.plan,
      additionalDirectoriesUnsupported: outcome.additionalDirectoriesUnsupported
    )
  }

  private func assess(
    _ draft: SessionDraft,
    inspections: [RepositoryID: RepositoryInspection],
    readingMissing: Bool
  ) async -> SessionCreationPreview {
    var issues = draft.validate()
    var workspacePlan: SessionWorkspacePlan?
    var previewSession: WorkSession?

    if let workspace {
      // Only the folders already read, unless reading is what was asked: the plan of a folder
      // nobody has designated through the panel yet waits for it to be.
      let known = inspections
      let readable =
        readingMissing
        ? draft.repositories
        : draft.repositories.filter {
          known[$0.id] != nil
        }
      if !readable.isEmpty, readable.count == draft.repositories.count {
        let taken = (try? await TakenSessionSlugs(repository: repository)()) ?? [:]
        let plan = await workspace.plan(
          slug: draft.slug,
          repositories: draft.repositories,
          inspections: known,
          takenSlugs: taken
        )
        workspacePlan = plan
        // The slug is only a problem once it names a branch.
        if plan.usesSessionBranch, let problem = SessionSlug.validationProblem(for: draft.slugText)
        {
          issues.append(.slugInvalid(problem))
        }
        issues.append(contentsOf: plan.sessionIssues)
        if let main = plan.repositories.first, let blocking = main.blockingIssue {
          issues.append(Self.mainRepositoryIssue(blocking))
        }
        previewSession = draft.session(
          createdAt: clock.now(),
          repositories: plan.repositories.map { plan in
            // Shown as the preparation will leave it: a worktree the plan creates is described
            // by where it will be, not by the fact that it does not exist yet.
            var context = plan.context(attachedAt: clock.now())
            if case .createWorktree = plan.action { context.worktreePath = plan.worktreePath }
            return context
          },
          slug: plan.usesSessionBranch ? draft.slug : nil
        )
      }
    } else if readingMissing, let path = draft.resolvedWorkingDirectoryPath, path.hasPrefix("/") {
      switch await folders.inspect(path: path) {
      case .usable:
        break
      case .missing:
        issues.append(.workingDirectoryNotFound)
      case .notADirectory:
        issues.append(.workingDirectoryNotADirectory)
      case .unreadable:
        issues.append(.workingDirectoryUnreadable)
      }
    }

    guard let providerID = draft.providerID, !providerID.isEmpty else {
      return SessionCreationPreview(issues: issues, workspace: workspacePlan)
    }
    guard let provider = await agents.provider(id: AgentProviderID(providerID)) else {
      issues.append(.agentUnknown(providerID))
      return SessionCreationPreview(issues: issues, workspace: workspacePlan)
    }

    let availability = await provider.availability(forceRefresh: false)
    if !availability.isUsable {
      issues.append(
        .agentUnavailable(
          name: provider.descriptor.displayName,
          summary: availability.diagnostic.summary,
          remedy: AgentRemediation.sentence(for: availability.diagnostic.remediations)
        )
      )
    }

    if let modelID = draft.modelID {
      let models = await provider.models()
      // An empty catalogue means the CLI never wrote one, not that the model is wrong: refusing
      // here would block a launch the agent would have accepted.
      if !models.isEmpty, !models.contains(where: { $0.id == modelID }) {
        issues.append(.modelUnknown(modelID))
      }
    }

    guard let path = draft.resolvedWorkingDirectoryPath else {
      return SessionCreationPreview(issues: issues, workspace: workspacePlan)
    }

    let session = previewSession ?? draft.session(createdAt: clock.now())
    let root = await workspace?.root.worktreeRootPath()
    let context = try? SessionLaunchContext.make(for: session, worktreeRootPath: root)
    let prompt = draft.trimmedPrompt.isEmpty ? nil : draft.initialPrompt
    let takesPrompt = provider.descriptor.capabilities.supportsInitialPrompt
    let sent = takesPrompt ? context?.prompt(with: prompt) : prompt
    // What the sheet shows is what goes: the summarised list when the whole would not fit.
    var shownConvention = takesPrompt ? context?.convention : nil
    if let full = shownConvention, let summarized = context?.summarizedConvention,
      let sent, !sent.hasPrefix(full), sent.hasPrefix(summarized)
    {
      shownConvention = summarized
    }
    let request =
      context?.request(modelID: draft.modelID, prompt: sent)
      ?? AgentLaunchRequest(
        workingDirectoryPath: path,
        modelID: draft.modelID,
        initialPrompt: prompt,
        resume: .none
      )
    let unsupported =
      !(context?.additionalWorkingDirectoryPaths.isEmpty ?? true)
      && !provider.descriptor.capabilities.supportsAdditionalDirectories

    do {
      let plan = try await provider.launchPlan(for: request)
      return SessionCreationPreview(
        issues: issues,
        workspace: workspacePlan,
        convention: shownConvention,
        plan: plan,
        additionalDirectoriesUnsupported: unsupported
      )
    } catch let error as AgentLaunchError {
      issues.append(Self.issue(for: error, agentName: provider.descriptor.displayName))
    } catch {
      issues.append(
        .agentUnavailable(
          name: provider.descriptor.displayName,
          summary: "The command line could not be prepared.",
          remedy: "Try again, and report the failure if it persists."
        )
      )
    }
    return SessionCreationPreview(
      issues: issues,
      workspace: workspacePlan,
      convention: shownConvention,
      additionalDirectoriesUnsupported: unsupported
    )
  }

  /// A main repository that cannot be prepared is the one conflict that holds the whole session
  /// back — there would be nowhere to start the agent. Its folder problems keep the wording and
  /// the field they always had.
  private static func mainRepositoryIssue(_ issue: RepositoryAttachmentIssue) -> SessionDraftIssue {
    switch issue.kind {
    case .folderUnusable:
      return SessionDraftIssue(
        field: .workingDirectory, message: issue.message, remedy: issue.remedy)
    default:
      return .mainRepositoryBlocked
    }
  }

  private static func issue(for error: AgentLaunchError, agentName: String) -> SessionDraftIssue {
    switch error {
    case .promptTooLarge(let byteCount, let limit):
      return .promptRejected(
        message: "The initial prompt is \(byteCount) bytes, and \(agentName) accepts \(limit).",
        remedy: "Shorten it, or create the session without a prompt and paste it in the terminal."
      )
    case .initialPromptUnsupported:
      return .promptRejected(
        message: "\(agentName) does not accept an initial prompt.",
        remedy: "Create the session without one and type it in the terminal."
      )
    case .unsupportedModel(let id):
      return .modelUnknown(id)
    case .modelSelectionUnsupported:
      return SessionDraftIssue(
        field: .model,
        message: "\(agentName) does not let Vibe Manager choose a model.",
        remedy: "Go back to the default model of the agent."
      )
    case .invalidWorkingDirectory:
      return .workingDirectoryNotAbsolute
    case .unavailable, .resumeUnsupported, .missingResumeIdentifier:
      return .agentUnavailable(
        name: agentName,
        summary: error.errorDescription ?? "It cannot be launched.",
        remedy: "Pick another agent, or detect again."
      )
    }
  }

}
