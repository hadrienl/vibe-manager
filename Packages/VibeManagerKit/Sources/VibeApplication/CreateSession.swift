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

  public init(
    repository: any SessionRepository,
    agents: any AgentProviderResolving,
    folders: any WorkingDirectoryProbe = FileManagerWorkingDirectoryProbe(),
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.repository = repository
    self.agents = agents
    self.folders = folders
    self.clock = clock
  }

  /// Everything wrong with this draft right now, without creating anything.
  public func problems(with draft: SessionDraft) async -> [SessionDraftIssue] {
    await evaluate(draft).issues
  }

  public func callAsFunction(_ draft: SessionDraft) async throws -> SessionCreation {
    // Re-checked here rather than trusted from the sheet: a CLI can be uninstalled, and a folder
    // deleted, between the moment the form was filled and the moment Create is pressed.
    let (issues, plan) = await evaluate(draft)
    guard issues.isEmpty, let plan else {
      throw SessionCreationRejected(issues: issues)
    }

    let session = draft.session(createdAt: clock.now())
    try await repository.save(session)
    return SessionCreation(session: session, plan: plan)
  }

  private func evaluate(
    _ draft: SessionDraft
  ) async -> (issues: [SessionDraftIssue], plan: AgentLaunchPlan?) {
    var issues = draft.validate()

    if let path = draft.resolvedWorkingDirectoryPath, path.hasPrefix("/") {
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
      initialPrompt: prompt.isEmpty ? nil : draft.initialPrompt,
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
          summary: "The command line could not be prepared.",
          remedy: "Try again, and report the failure if it persists."
        )
      )
      return (issues, nil)
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
