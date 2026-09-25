import Foundation
import VibeDomain

public struct SessionCreation: Sendable {
  public let session: WorkSession
  /// The plan the caller must launch — the very one whose problems were just checked, and, for
  /// Claude Code, the one carrying the session identifier the conversation will be named with.
  public let plan: AgentLaunchPlan

  public init(session: WorkSession, plan: AgentLaunchPlan) {
    self.session = session
    self.plan = plan
  }
}

public struct SessionCreationRejected: Error, Equatable, Sendable {
  public let issues: [SessionDraftIssue]

  public init(issues: [SessionDraftIssue]) {
    self.issues = issues
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
  /// Turns a ticket typed as `#12` into its address, from the working folder's repository (#69).
  private let ticketContext: ReadTicketContext?

  public init(
    repository: any SessionRepository,
    agents: any AgentProviderResolving,
    folders: any WorkingDirectoryProbe = FileManagerWorkingDirectoryProbe(),
    clock: any SessionClock = SystemSessionClock(),
    ticketContext: ReadTicketContext? = nil
  ) {
    self.repository = repository
    self.agents = agents
    self.folders = folders
    self.clock = clock
    self.ticketContext = ticketContext
  }

  /// Everything wrong with this draft right now, without creating anything.
  ///
  /// The working folder is only opened when `checkingFolder` is asked for, and the default is to
  /// leave it alone. Typing a path is not a request to read it: on a Mac, opening `~/Documents`
  /// raises a system consent alert, and doing that on every keystroke put the alert in the middle
  /// of the form. The folder is checked where the user actually designates one — at the return of
  /// the open panel, and at creation.
  public func problems(
    with draft: SessionDraft,
    checkingFolder: Bool = false
  ) async -> [SessionDraftIssue] {
    await evaluate(draft, checkingFolder: checkingFolder).issues
  }

  public func callAsFunction(_ draft: SessionDraft) async throws -> SessionCreation {
    // Re-checked here rather than trusted from the sheet: a CLI can be uninstalled, and a folder
    // deleted, between the moment the form was filled and the moment Create is pressed.
    let (issues, plan) = await evaluate(draft, checkingFolder: true)
    guard issues.isEmpty, let plan else {
      throw SessionCreationRejected(issues: issues)
    }

    var forge: RepositoryWebAddress?
    if let ticketContext, let path = draft.resolvedWorkingDirectoryPath {
      forge = await ticketContext(path: path).repository
    }
    let session = draft.session(createdAt: clock.now(), repository: forge)
    try await repository.save(session)
    return SessionCreation(session: session, plan: plan)
  }

  /// The draft's problems, each stated once.
  ///
  /// Two checks can reach the same conclusion — a relative folder is caught by the draft and
  /// again by the agent refusing to plan a launch — and an issue is identified by its field and
  /// its sentence, so a repeat would collide in the lists the sheet renders and would be counted
  /// twice in its footer.
  private func evaluate(
    _ draft: SessionDraft,
    checkingFolder: Bool
  ) async -> (issues: [SessionDraftIssue], plan: AgentLaunchPlan?) {
    let outcome = await assess(draft, checkingFolder: checkingFolder)
    var seen: Set<SessionDraftIssue.ID> = []
    return (outcome.issues.filter { seen.insert($0.id).inserted }, outcome.plan)
  }

  private func assess(
    _ draft: SessionDraft,
    checkingFolder: Bool
  ) async -> (issues: [SessionDraftIssue], plan: AgentLaunchPlan?) {
    var issues = draft.validate()

    if checkingFolder, let path = draft.resolvedWorkingDirectoryPath, path.hasPrefix("/") {
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
      return (issues, nil)
    }
    guard let provider = await agents.provider(id: AgentProviderID(providerID)) else {
      issues.append(.agentUnknown(providerID))
      return (issues, nil)
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

    guard let path = draft.resolvedWorkingDirectoryPath else { return (issues, nil) }

    let prompt = draft.trimmedPrompt
    let request = AgentLaunchRequest(
      workingDirectoryPath: path,
      modelID: draft.modelID,
      initialPrompt: prompt.isEmpty ? nil : draft.effectivePrompt,
      resume: .none
    )

    do {
      return (issues, try await provider.launchPlan(for: request))
    } catch let error as AgentLaunchError {
      issues.append(Self.issue(for: error, agentName: provider.descriptor.displayName))
      return (issues, nil)
    } catch {
      issues.append(
        .agentUnavailable(
          name: provider.descriptor.displayName,
          summary: String(localized: "The command line could not be prepared.", bundle: .module),
          remedy: String(
            localized: "Try again, and report the failure if it persists.", bundle: .module)
        )
      )
      return (issues, nil)
    }
  }

  private static func issue(for error: AgentLaunchError, agentName: String) -> SessionDraftIssue {
    switch error {
    case .promptTooLarge(let byteCount, let limit):
      return .promptRejected(
        message: String(
          localized:
            "The initial prompt is \(String(byteCount)) bytes, and \(agentName) accepts \(String(limit)).",
          bundle: .module),
        remedy: String(
          localized:
            "Shorten it, or create the session without a prompt and paste it in the terminal.",
          bundle: .module)
      )
    case .promptContainsNullCharacter:
      // The draft already says so, and one character is worth one problem, not two.
      return .promptControlCharacters
    case .initialPromptUnsupported:
      return .promptRejected(
        message: String(
          localized: "\(agentName) does not accept an initial prompt.", bundle: .module),
        remedy: String(
          localized: "Create the session without one and type it in the terminal.", bundle: .module)
      )
    case .unsupportedModel(let id):
      return .modelUnknown(id)
    case .modelSelectionUnsupported:
      return SessionDraftIssue(
        field: .model,
        message: String(
          localized: "\(agentName) does not let Vibe Manager choose a model.", bundle: .module),
        remedy: String(localized: "Go back to the default model of the agent.", bundle: .module)
      )
    case .invalidWorkingDirectory:
      return .workingDirectoryNotAbsolute
    case .unavailable, .resumeUnsupported, .missingResumeIdentifier:
      return .agentUnavailable(
        name: agentName,
        summary: error.errorDescription
          ?? String(localized: "It cannot be launched.", bundle: .module),
        remedy: String(localized: "Pick another agent, or detect again.", bundle: .module)
      )
    }
  }

}
