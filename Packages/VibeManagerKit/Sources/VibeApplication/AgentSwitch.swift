import Foundation
import VibeDomain

/// The agent and model a session is being moved to. `modelID == nil` is the agent's own default.
public struct AgentTarget: Hashable, Sendable {
  public let providerID: String
  public let modelID: String?

  public init(providerID: String, modelID: String? = nil) {
    self.providerID = providerID
    self.modelID = modelID
  }

  public func matches(_ agent: SessionAgentConfiguration?) -> Bool {
    agent?.providerID == providerID && agent?.modelID == modelID
  }
}

/// How the agent a session is switched to picks the work up.
public enum AgentSwitchMode: Equatable, Sendable {
  /// Same agent, another model: its own conversation goes on, and no text is sent.
  case resumeWithModel(identifier: String)
  /// The session never ran: the new agent gets the launch it never had, initial prompt included.
  case firstLaunch
  /// A new process, handed a summary of the session.
  case handover(SessionContextBrief)
  /// A new process, told nothing: the summary was emptied, or the agent takes no prompt.
  case freshWithoutContext

  /// The mode without what it carries: what the sheet showed, compared with what the plan chose.
  public enum Kind: Equatable, Sendable {
    case resumeWithModel, firstLaunch, handover, freshWithoutContext
  }

  public var kind: Kind {
    switch self {
    case .resumeWithModel: return .resumeWithModel
    case .firstLaunch: return .firstLaunch
    case .handover: return .handover
    case .freshWithoutContext: return .freshWithoutContext
    }
  }

  public var brief: SessionContextBrief? {
    guard case .handover(let brief) = self else { return nil }
    return brief
  }

  public var keepsConversation: Bool {
    if case .resumeWithModel = self { return true }
    return false
  }

  func handover(wasEdited: Bool) -> AgentChange.Handover {
    switch self {
    case .resumeWithModel: return .resumedConversation
    case .firstLaunch: return .initialPrompt
    case .handover(let brief):
      return .summary(
        byteCount: brief.text.utf8.count, isTruncated: brief.isTruncated, wasEdited: wasEdited)
    case .freshWithoutContext: return .nothing
    }
  }
}

/// Everything that stops a switch. None of them has stopped an agent or written anything, except
/// `stopUnconfirmed` and `sessionMoved`, which are only reached after the stop and say so.
public enum AgentSwitchRefusal: Error, Equatable, Sendable, LocalizedError {
  case sessionMissing
  case storeUnreadable
  case notSwitchable(SessionStatus)
  case agentUnassigned
  case nothingToChange
  case noRepository
  case targetUnknown(String)
  case targetUnavailable(name: String, summary: String, remedy: String)
  case modelUnknown(model: String, agentName: String)
  case summaryTooLong(overBy: Int)
  case workingDirectoryUnusable(path: String, status: WorkingDirectoryStatus)
  case launchRejected(AgentLaunchError)
  /// The running agent could not be confirmed stopped. Nothing was switched.
  case stopUnconfirmed(processIdentifier: Int32)
  /// The session was archived or removed while its agent was being stopped.
  case sessionMoved
  /// The session changed while the sheet was open, and the switch would no longer do what the
  /// sheet said: resume a conversation it announced a summary for, or the reverse.
  case planChanged

  public var errorDescription: String? {
    switch self {
    case .sessionMissing:
      return "This session is no longer in the store."
    case .storeUnreadable:
      return "The session store could not be read."
    case .notSwitchable(.archived):
      return "This session is archived."
    case .notSwitchable:
      return "This session cannot be switched right now."
    case .agentUnassigned:
      return "This session was never given a coding agent."
    case .nothingToChange:
      return "This session already runs that agent and model."
    case .noRepository:
      return "This session has no folder to start in."
    case .targetUnknown(let providerID):
      return "The agent \(providerID) is not installed in this build."
    case .targetUnavailable(let name, let summary, _):
      return "\(name) cannot run right now: \(summary)"
    case .modelUnknown(let model, let agentName):
      return "\(agentName) does not offer the model \(model)."
    case .summaryTooLong(let overBy):
      return """
        The summary is \(Self.size(overBy)) over what an agent can be started with.
        """
    case .workingDirectoryUnusable(let path, .missing):
      return "The folder of this session, \(path), no longer exists."
    case .workingDirectoryUnusable(let path, .notADirectory):
      return "The path of this session, \(path), is not a folder any more."
    case .workingDirectoryUnusable(let path, _):
      return "The folder of this session, \(path), cannot be entered."
    case .launchRejected(let error):
      return error.errorDescription
    case .stopUnconfirmed(let pid):
      return "The running agent (process \(pid)) could not be confirmed stopped."
    case .sessionMoved:
      return "This session was archived while its agent was being stopped."
    case .planChanged:
      return "This session changed while the switch was being prepared, so nothing was switched."
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .sessionMissing, .sessionMoved:
      return "Reload the workspace."
    case .planChanged:
      return "Open Switch Agent again to review what will be handed over."
    case .storeUnreadable:
      return "Try again, and restore a backup if it persists."
    case .notSwitchable(.archived):
      return "Unarchive it first, then switch its agent."
    case .notSwitchable, .nothingToChange:
      return nil
    case .agentUnassigned:
      return "Create a new session to choose an agent."
    case .noRepository:
      return "Create a new session in the folder you want to work in."
    case .targetUnknown:
      return "Choose another agent."
    case .targetUnavailable(_, _, let remedy):
      return remedy
    case .modelUnknown:
      return "Choose one of the models it lists, or its default model."
    case .summaryTooLong:
      return "Shorten the summary."
    case .workingDirectoryUnusable:
      return "Put the folder back where it was, or create a new session in its new place."
    case .launchRejected:
      return "Try again, and report the failure if it persists."
    case .stopUnconfirmed:
      return "The session was left on its agent. Check that the process is gone, then try again."
    }
  }

  static func size(_ bytes: Int) -> String {
    bytes < 1_024 ? "\(bytes) bytes" : String(format: "%.1f KiB", Double(bytes) / 1_024)
  }
}

/// A switch that is ready to run: the very plan that will be launched, and how it hands over.
public struct AgentSwitchPlan: Sendable {
  public let session: WorkSession
  public let target: AgentTarget
  public let targetName: String
  public let plan: AgentLaunchPlan
  public let mode: AgentSwitchMode

  public init(
    session: WorkSession,
    target: AgentTarget,
    targetName: String,
    plan: AgentLaunchPlan,
    mode: AgentSwitchMode
  ) {
    self.session = session
    self.target = target
    self.targetName = targetName
    self.plan = plan
    self.mode = mode
  }

  /// The configuration the session will carry: the resumed conversation's identifier when it goes
  /// on, none otherwise — the new agent's own is recorded once its launch reveals it.
  public var nextConfiguration: SessionAgentConfiguration {
    let identifier: String?
    if case .resumeWithModel(let resumed) = mode {
      identifier = resumed
    } else {
      identifier = nil
    }
    return SessionAgentConfiguration(
      providerID: target.providerID,
      modelID: target.modelID,
      resumeIdentifier: identifier
    )
  }
}

/// Plans a switch of agent or model, and neither stops nor writes anything.
///
/// Everything that can refuse a switch refuses it here, while the current agent is still running:
/// an agent that is not signed in, a model it does not offer, a folder that is gone or a summary
/// that does not fit must not cost the user the agent that was working.
public struct PlanAgentSwitch: Sendable {
  private let repository: any SessionRepository
  private let agents: any AgentProviderResolving
  private let folders: any WorkingDirectoryProbe
  private let brief: SessionContextBriefBuilder

  public init(
    repository: any SessionRepository,
    agents: any AgentProviderResolving,
    folders: any WorkingDirectoryProbe = FileManagerWorkingDirectoryProbe(),
    brief: SessionContextBriefBuilder = SessionContextBriefBuilder()
  ) {
    self.repository = repository
    self.agents = agents
    self.folders = folders
    self.brief = brief
  }

  /// The summary the target would be handed, for the sheet to show before anything is decided.
  public func summary(
    for input: SessionBriefInput,
    to target: AgentTarget
  ) -> SessionContextBrief {
    brief.handover(
      input,
      to: SessionAgentConfiguration(providerID: target.providerID, modelID: target.modelID)
    )
  }

  /// - Parameters:
  ///   - context: the branch report and Git states known right now, and the agents' names.
  ///   - summaryOverride: the summary as the user left it in the sheet. Empty means "tell it
  ///     nothing"; `nil` means the generated one.
  ///   - skippingResume: do not try the agent's own resume — it dropped this conversation last
  ///     time, and the user did not ask to try again.
  ///   - expecting: the mode the sheet showed. A plan that turns out otherwise is refused rather
  ///     than run: a summary nobody read must not be sent, nor one somebody read be dropped.
  public func callAsFunction(
    id: SessionID,
    to target: AgentTarget,
    context: SessionBriefInput? = nil,
    summaryOverride: String? = nil,
    skippingResume: Bool = false,
    expecting: AgentSwitchMode.Kind? = nil
  ) async throws -> AgentSwitchPlan {
    let planned = try await plan(
      id: id, to: target, context: context, summaryOverride: summaryOverride,
      skippingResume: skippingResume)
    if let expecting, planned.mode.kind != expecting {
      throw AgentSwitchRefusal.planChanged
    }
    return planned
  }

  private func plan(
    id: SessionID,
    to target: AgentTarget,
    context: SessionBriefInput?,
    summaryOverride: String?,
    skippingResume: Bool
  ) async throws -> AgentSwitchPlan {
    let stored: WorkSession?
    do {
      stored = try await repository.session(id: id)
    } catch {
      throw AgentSwitchRefusal.storeUnreadable
    }
    guard let session = stored else { throw AgentSwitchRefusal.sessionMissing }
    guard session.status != .archived else {
      throw AgentSwitchRefusal.notSwitchable(session.status)
    }
    guard let current = session.agent else { throw AgentSwitchRefusal.agentUnassigned }
    guard !target.matches(current) else { throw AgentSwitchRefusal.nothingToChange }

    guard let provider = await agents.provider(id: AgentProviderID(target.providerID)) else {
      throw AgentSwitchRefusal.targetUnknown(target.providerID)
    }
    let descriptor = provider.descriptor
    let availability = await provider.availability(forceRefresh: false)
    guard availability.isUsable else {
      throw AgentSwitchRefusal.targetUnavailable(
        name: descriptor.displayName,
        summary: availability.diagnostic.summary,
        remedy: AgentRemediation.sentence(for: availability.diagnostic.remediations)
      )
    }
    if let model = target.modelID {
      // Only against a catalogue that exists: an agent that published none still takes a model
      // it is asked for, as at creation.
      let models = await provider.models()
      if !models.isEmpty, !models.contains(where: { $0.id == model }) {
        throw AgentSwitchRefusal.modelUnknown(model: model, agentName: descriptor.displayName)
      }
    }

    guard let path = RestartSession.workingDirectoryPath(of: session) else {
      throw AgentSwitchRefusal.noRepository
    }
    let status = await folders.inspect(path: path)
    guard status == .usable else {
      throw AgentSwitchRefusal.workingDirectoryUnusable(path: path, status: status)
    }

    func plan(prompt: String?, resume: AgentResumeRequest) async throws -> AgentLaunchPlan {
      do {
        return try await provider.launchPlan(
          for: AgentLaunchRequest(
            workingDirectoryPath: path,
            modelID: target.modelID,
            initialPrompt: prompt,
            resume: resume
          )
        )
      } catch let error as AgentLaunchError {
        throw AgentSwitchRefusal.launchRejected(error)
      }
    }
    func planned(_ launch: AgentLaunchPlan, _ mode: AgentSwitchMode) -> AgentSwitchPlan {
      AgentSwitchPlan(
        session: session,
        target: target,
        targetName: descriptor.displayName,
        plan: launch,
        mode: mode
      )
    }

    // A session that never ran has no conversation and nothing to summarise: the new agent gets
    // the launch the previous one never had.
    if !session.hasEverStarted {
      let prompt = session.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
      let launch = try await plan(
        prompt: prompt.isEmpty ? nil : session.initialPrompt, resume: .none)
      return planned(launch, .firstLaunch)
    }

    if !skippingResume, current.providerID == target.providerID,
      descriptor.capabilities.supportsResume,
      let identifier = current.resumeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
      !identifier.isEmpty
    {
      do {
        let launch = try await provider.launchPlan(
          for: AgentLaunchRequest(
            workingDirectoryPath: path,
            modelID: target.modelID,
            initialPrompt: nil,
            resume: .identifier(identifier)
          )
        )
        return planned(launch, .resumeWithModel(identifier: identifier))
      } catch AgentLaunchError.missingResumeIdentifier, AgentLaunchError.resumeUnsupported {
        // A conversation the CLI would not take back is handed over like any other.
      } catch let error as AgentLaunchError {
        throw AgentSwitchRefusal.launchRejected(error)
      }
    }

    guard descriptor.capabilities.supportsInitialPrompt else {
      return planned(try await plan(prompt: nil, resume: .none), .freshWithoutContext)
    }

    let generated = self.summary(for: context ?? SessionBriefInput(session: session), to: target)
    let summary: SessionContextBrief
    if let summaryOverride, summaryOverride != generated.text {
      guard !summaryOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return planned(try await plan(prompt: nil, resume: .none), .freshWithoutContext)
      }
      let overflow = summaryOverride.utf8.count - brief.byteLimit
      summary = SessionContextBrief(
        text: summaryOverride,
        isTruncated: false,
        includedSections: [],
        overflowByteCount: max(0, overflow)
      )
    } else {
      // The text the sheet showed untouched keeps what is known of it — shortened, and from what.
      summary = generated
    }
    // Never cut here: the user is told by how much, and shortens it themselves.
    guard summary.fits else {
      throw AgentSwitchRefusal.summaryTooLong(overBy: summary.overflowByteCount)
    }
    return planned(try await plan(prompt: summary.text, resume: .none), .handover(summary))
  }
}

/// Writes a planned switch on the session: the agent it leaves goes into the history, the next
/// one becomes current. Only `agent` and `agentHistory` are written.
public struct RecordAgentSwitch: Sendable {
  private let repository: any SessionRepository
  private let clock: any SessionClock

  public init(repository: any SessionRepository, clock: any SessionClock = SystemSessionClock()) {
    self.repository = repository
    self.clock = clock
  }

  public func callAsFunction(_ plan: AgentSwitchPlan, wasEdited: Bool) async throws -> AgentChange {
    let now = clock.now()
    let next = plan.nextConfiguration
    let handover = plan.mode.handover(wasEdited: wasEdited)
    let id = UUID()
    let updated: WorkSession?
    do {
      updated = try await repository.mutate(id: plan.session.id) { session in
        // Decided on the copy the write is made on: the stop just before may have raced an
        // archive, and an archived session is not handed to anyone.
        try session.switchAgent(to: next, handover: handover, at: now, id: id)
      }
    } catch AgentSwitchError.notClosed {
      throw AgentSwitchRefusal.sessionMoved
    }
    guard let change = updated?.agentHistory.last, change.id == id else {
      throw AgentSwitchRefusal.sessionMissing
    }
    return change
  }
}

/// Puts a session back on the agent a switch left, because the next one never ran.
public struct RevertAgentSwitch: Sendable {
  private let repository: any SessionRepository

  public init(repository: any SessionRepository) {
    self.repository = repository
  }

  public func callAsFunction(
    id: SessionID,
    change: AgentChange.ID,
    reason: String
  ) async throws {
    _ = try await repository.mutate(id: id) { session in
      try session.revertAgentSwitch(change, reason: reason)
    }
  }
}
