import Foundation
import VibeDomain

/// How a closed session is put back to work.
///
/// One verb is offered to the user — Restart — and these are the ways it can be honoured. Which
/// one applies is decided from what the session carries, never from what the interface guessed.
public enum SessionRestartMode: Equatable, Sendable {
  /// The session was created but never ran: this is its first launch, plan and all.
  case firstLaunch
  /// The agent's own conversation is resumed, with the identifier it was given or discovered.
  case native(identifier: String)
  /// A new process, handed a summary of what the session carries.
  case freshWithContext(SessionContextBrief)
  /// A new process, with no summary: this agent takes no initial prompt at all.
  case freshWithoutContext

  /// Whether the user is asked before this runs. A resume loses nothing and has nothing to
  /// confirm; a fresh start sends a text to an agent, and a text is read before it is sent.
  public var needsConfirmation: Bool {
    switch self {
    case .firstLaunch, .native: return false
    case .freshWithContext, .freshWithoutContext: return true
    }
  }

  public var brief: SessionContextBrief? {
    guard case .freshWithContext(let brief) = self else { return nil }
    return brief
  }
}

/// Why this restart could not resume the agent's own conversation.
///
/// Always said, never implied: the user is about to start a second conversation on the same
/// work, and the reason is what tells them whether that is what they want.
public enum SessionRestartExplanation: Equatable, Sendable {
  /// The agent has no resume mechanism at all.
  case agentCannotResume(agentName: String)
  /// Nothing was ever captured for this session — a launch too short to reveal it, a rollout
  /// file that never appeared.
  case noResumeIdentifier(agentName: String)
  /// An identifier is stored, but the CLI would refuse it.
  case identifierRejected(agentName: String)
  /// The user asked for a fresh start after a resume failed in front of them.
  case resumeDeclined(agentName: String)
  /// The conversation was resumed once and the agent dropped it within seconds.
  case resumeFailedBefore(agentName: String)

  public var sentence: String {
    switch self {
    case .agentCannotResume(let name):
      return "\(name) cannot resume a previous conversation."
    case .noResumeIdentifier(let name):
      return "\(name) kept no identifier for this session, so its conversation cannot be found."
    case .identifierRejected(let name):
      return "The identifier stored for this session is not one \(name) would accept."
    case .resumeDeclined(let name):
      return "Restarting without resuming the \(name) conversation, as you asked."
    case .resumeFailedBefore(let name):
      return """
        \(name) stopped as soon as this conversation was resumed last time, so it is not being \
        resumed again.
        """
    }
  }
}

/// Why a restart is not even trying the agent's own resume.
public enum SessionResumeSkip: Equatable, Sendable {
  /// The conversation was already found unresumable, and the user has answered the summary this
  /// restart is about to send. Asking the agent again would only offer it a second refusal.
  case alreadyAnswered
  /// The agent dropped this conversation within seconds of being handed it, the last time it was
  /// tried. Handing it back would repeat that in front of the user.
  case failedLastTime

  var explanation: (String) -> SessionRestartExplanation {
    switch self {
    case .alreadyAnswered: return SessionRestartExplanation.resumeDeclined
    case .failedLastTime: return SessionRestartExplanation.resumeFailedBefore
    }
  }
}

/// Everything that can stop a restart before anything is launched or written.
public enum SessionRestartRefusal: Error, Equatable, Sendable, LocalizedError {
  case sessionMissing
  /// The store itself could not be asked. Kept apart from `sessionMissing`, which claims the
  /// session is gone — a statement about the store that a failed read has not established.
  case storeUnreadable
  case notRestartable(SessionStatus)
  case agentUnassigned
  case agentUnknown(String)
  case agentUnavailable(name: String, summary: String, remedy: String)
  case noRepository
  case workingDirectoryUnusable(path: String, status: WorkingDirectoryStatus)
  /// The main repository's worktree is gone. Recreating it is a gesture, not a side effect.
  case mainWorktreeMissing(name: String, path: String)
  /// The main repository was never prepared, or no longer is.
  case mainRepositoryUnprepared(name: String, reason: String)
  case launchRejected(AgentLaunchError)

  public var errorDescription: String? {
    switch self {
    case .sessionMissing:
      return "This session is no longer in the store."
    case .storeUnreadable:
      return "The session store could not be read."
    case .notRestartable(.active):
      return "This session is already running."
    case .notRestartable(.archived):
      return "This session is archived."
    case .notRestartable:
      return "This session cannot be restarted."
    case .agentUnassigned:
      return "This session was never given a coding agent."
    case .agentUnknown(let providerID):
      return "The agent that ran this session, \(providerID), is not installed in this build."
    case .agentUnavailable(let name, let summary, _):
      return "\(name) cannot run right now: \(summary)"
    case .noRepository:
      return "This session has no folder to start in."
    case .workingDirectoryUnusable(let path, .missing):
      return "The folder of this session, \(path), no longer exists."
    case .workingDirectoryUnusable(let path, .notADirectory):
      return "The path of this session, \(path), is not a folder any more."
    case .workingDirectoryUnusable(let path, _):
      return "The folder of this session, \(path), cannot be entered."
    case .mainWorktreeMissing(let name, let path):
      return "The worktree of \(name), the main repository, no longer exists at \(path)."
    case .mainRepositoryUnprepared(let name, let reason):
      return "\(name), the main repository, is not ready: \(reason)"
    case .launchRejected(let error):
      return error.errorDescription
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .sessionMissing:
      return "Reload the workspace."
    case .storeUnreadable:
      return "Try again, and restore a backup if it persists."
    case .notRestartable(.archived):
      return "Unarchive it first, then restart it."
    case .notRestartable(.active):
      return "Close it first if you want to start it again."
    case .notRestartable:
      return nil
    case .agentUnassigned:
      return "Create a new session to choose an agent."
    case .agentUnknown:
      return "Install that agent, or create a new session with one that is available."
    case .agentUnavailable(_, _, let remedy):
      return remedy
    case .noRepository:
      return "Create a new session in the folder you want to work in."
    case .workingDirectoryUnusable:
      return "Put the folder back where it was, or create a new session in its new place."
    case .mainWorktreeMissing, .mainRepositoryUnprepared:
      return "Recreate the worktree from the inspector, or make another repository the main one."
    case .launchRejected:
      return "Try again, and report the failure if it persists."
    }
  }
}

/// A restart that is ready to run: the very plan that will be launched, and why it looks the way
/// it does.
public struct SessionRestart: Sendable {
  public let session: WorkSession
  public let plan: AgentLaunchPlan
  public let mode: SessionRestartMode
  /// Why the agent's own conversation is not being resumed. `nil` when it is.
  public let explanation: SessionRestartExplanation?
  /// What the verification found and did not stop the launch for: a secondary repository that
  /// is missing and left out, a worktree on another branch than the one recorded.
  public let warnings: [String]

  public init(
    session: WorkSession,
    plan: AgentLaunchPlan,
    mode: SessionRestartMode,
    explanation: SessionRestartExplanation?,
    warnings: [String] = []
  ) {
    self.session = session
    self.plan = plan
    self.mode = mode
    self.explanation = explanation
    self.warnings = warnings
  }

  public var needsConfirmation: Bool { mode.needsConfirmation }
}

/// Puts a closed session back to work, from what the store already knows about it.
///
/// The twin of `CreateSession`, and deliberately shaped like it: it validates, it builds the plan
/// that will be launched, and it starts nothing. Launching stays with the one object that knows
/// what is already running, so there is no second road to a process.
///
/// Nothing here is re-chosen. The provider, the model, the folder and the identity all come back
/// out of the session exactly as they went in — which is the whole of "the same agent, folder and
/// appearance are reused", stated once instead of trusted to an interface.
public struct RestartSession: Sendable {
  private let repository: any SessionRepository
  private let agents: any AgentProviderResolving
  private let folders: any WorkingDirectoryProbe
  private let brief: SessionContextBriefBuilder
  private let verify: VerifySessionWorkspace
  private let root: (any WorktreeRootProviding)?

  public init(
    repository: any SessionRepository,
    agents: any AgentProviderResolving,
    folders: any WorkingDirectoryProbe = FileManagerWorkingDirectoryProbe(),
    brief: SessionContextBriefBuilder = SessionContextBriefBuilder(),
    workspace: SessionWorkspaceServices? = nil
  ) {
    self.repository = repository
    self.agents = agents
    self.folders = folders
    self.brief = brief
    verify = VerifySessionWorkspace(folders: folders, inspector: workspace?.inspector)
    root = workspace?.root
  }

  /// - Parameters:
  ///   - contextOverride: the summary the user edited, used in place of the generated one.
  ///   - skippingResume: do not try the agent's own resume, and say why in the explanation.
  public func callAsFunction(
    id: SessionID,
    contextOverride: String? = nil,
    skippingResume: SessionResumeSkip? = nil
  ) async throws -> SessionRestart {
    // Read from the store, never from the list on screen: a session the sidebar still draws as
    // closed may have been reopened or archived since that list was loaded.
    guard let session = try await repository.session(id: id) else {
      throw SessionRestartRefusal.sessionMissing
    }
    guard session.status == .closed else {
      throw SessionRestartRefusal.notRestartable(session.status)
    }

    guard let configuration = session.agent else { throw SessionRestartRefusal.agentUnassigned }
    guard let provider = await agents.provider(id: AgentProviderID(configuration.providerID))
    else {
      throw SessionRestartRefusal.agentUnknown(configuration.providerID)
    }

    let descriptor = provider.descriptor
    let availability = await provider.availability(forceRefresh: false)
    guard availability.isUsable else {
      throw SessionRestartRefusal.agentUnavailable(
        name: descriptor.displayName,
        summary: availability.diagnostic.summary,
        remedy: AgentRemediation.sentence(for: availability.diagnostic.remediations)
      )
    }

    // Every repository is read again before the launch rather than discovered by it: a worktree
    // deleted between two sessions is ordinary, and finding out through a terminal that dies on
    // `chdir` tells the user nothing they can act on.
    let (context, warnings) = try await launchContext(for: session)

    // Asked before anything is resumed: a session that has never run has no conversation to go
    // back to, whatever a stored identifier might claim, and what it is owed is the prompt it
    // was created with — not a summary apologising for a conversation that never existed.
    if !session.hasEverStarted {
      return try await firstLaunch(
        session: session, provider: provider, context: context, warnings: warnings)
    }

    if skippingResume == nil, descriptor.capabilities.supportsResume,
      let identifier = configuration.resumeIdentifier?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !identifier.isEmpty
    {
      do {
        // No prompt: the conversation being resumed already contains the instruction that
        // started it, and handing it back would set the agent off on it a second time.
        let plan = try await provider.launchPlan(
          for: context.request(
            modelID: configuration.modelID,
            prompt: nil,
            resume: .identifier(identifier)
          )
        )
        return SessionRestart(
          session: session,
          plan: plan,
          mode: .native(identifier: identifier),
          explanation: nil,
          warnings: warnings
        )
      } catch AgentLaunchError.missingResumeIdentifier, AgentLaunchError.resumeUnsupported {
        // A stored identifier the CLI would not take is precisely "this conversation cannot be
        // resumed", so it falls through to a fresh start rather than failing the restart.
        return try await fresh(
          session: session,
          provider: provider,
          context: context,
          warnings: warnings,
          contextOverride: contextOverride,
          explanation: .identifierRejected(agentName: descriptor.displayName)
        )
      } catch let error as AgentLaunchError {
        throw SessionRestartRefusal.launchRejected(error)
      }
    }

    let explanation: SessionRestartExplanation
    if let skippingResume {
      explanation = skippingResume.explanation(descriptor.displayName)
    } else if !descriptor.capabilities.supportsResume {
      explanation = .agentCannotResume(agentName: descriptor.displayName)
    } else {
      explanation = .noResumeIdentifier(agentName: descriptor.displayName)
    }
    return try await fresh(
      session: session,
      provider: provider,
      context: context,
      warnings: warnings,
      contextOverride: contextOverride,
      explanation: explanation
    )
  }

  // MARK: - Modes

  private func firstLaunch(
    session: WorkSession,
    provider: any AgentProvider,
    context: SessionLaunchContext,
    warnings: [String]
  ) async throws -> SessionRestart {
    // The convention goes first, exactly as it would have at creation: this *is* the creation's
    // launch, only later.
    let takesPrompt = provider.descriptor.capabilities.supportsInitialPrompt
    let initialPrompt =
      session.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? nil : session.initialPrompt
    let plan = try await launchPlan(
      from: provider,
      request: context.request(
        modelID: session.agent?.modelID,
        prompt: takesPrompt ? context.prompt(with: initialPrompt) : initialPrompt
      )
    )
    return SessionRestart(
      session: session, plan: plan, mode: .firstLaunch, explanation: nil, warnings: warnings)
  }

  private func fresh(
    session: WorkSession,
    provider: any AgentProvider,
    context: SessionLaunchContext,
    warnings: [String],
    contextOverride: String?,
    explanation: SessionRestartExplanation
  ) async throws -> SessionRestart {
    let bare = context.request(modelID: session.agent?.modelID, prompt: nil)
    guard provider.descriptor.capabilities.supportsInitialPrompt else {
      let plan = try await launchPlan(from: provider, request: bare)
      return SessionRestart(
        session: session,
        plan: plan,
        mode: .freshWithoutContext,
        explanation: explanation,
        warnings: warnings
      )
    }

    // An emptied summary is a real answer — "start it again, tell it nothing" — but it must not
    // be announced as a summary: the terminal's separator and the sheet both say one was sent.
    if let contextOverride, contextOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      let plan = try await launchPlan(from: provider, request: bare)
      return SessionRestart(
        session: session,
        plan: plan,
        mode: .freshWithoutContext,
        explanation: explanation,
        warnings: warnings
      )
    }

    let summary: SessionContextBrief
    if let contextOverride {
      // An edited summary goes through the same ceiling as a generated one: the user must not be
      // able to type a brief the agent would refuse to be started with.
      let clamped = brief.clamped(contextOverride)
      summary = SessionContextBrief(
        text: clamped,
        isTruncated: clamped.utf8.count != contextOverride.utf8.count,
        includedSections: []
      )
    } else {
      summary = brief(for: session, missing: Set(context.leftOut.map(\.id)))
    }

    let plan = try await launchPlan(
      from: provider,
      request: context.request(modelID: session.agent?.modelID, prompt: summary.text)
    )
    return SessionRestart(
      session: session,
      plan: plan,
      mode: .freshWithContext(summary),
      explanation: explanation,
      warnings: warnings
    )
  }

  private func launchPlan(
    from provider: any AgentProvider,
    request: AgentLaunchRequest
  ) async throws -> AgentLaunchPlan {
    do {
      return try await provider.launchPlan(for: request)
    } catch let error as AgentLaunchError {
      throw SessionRestartRefusal.launchRejected(error)
    }
  }

  /// Where the session starts, after every repository has been read again.
  ///
  /// The main repository decides: gone, or never prepared, and nothing is launched — recreating a
  /// worktree is a gesture the user makes, not a side effect of Restart. Any other repository
  /// that is missing is left out of this launch, still attached, and said.
  private func launchContext(
    for session: WorkSession
  ) async throws -> (SessionLaunchContext, [String]) {
    guard let main = session.repositories.first else {
      throw SessionRestartRefusal.noRepository
    }
    let verdicts = await verify(session)
    switch verdicts[main.id] ?? .ready {
    case .ready, .otherBranch:
      break
    case .worktreeMissing(let path):
      throw SessionRestartRefusal.mainWorktreeMissing(name: main.displayName, path: path)
    case .cloneMissing(let path):
      guard main.mode == .worktree else {
        throw SessionRestartRefusal.workingDirectoryUnusable(
          path: path, status: await folders.inspect(path: path))
      }
      throw SessionRestartRefusal.mainRepositoryUnprepared(
        name: main.displayName, reason: "its clone is no longer at \(path).")
    case .notPrepared(let failure):
      throw SessionRestartRefusal.mainRepositoryUnprepared(
        name: main.displayName, reason: failure.message)
    }

    let excluded = Set(
      session.repositories.compactMap { repository in
        verdicts[repository.id]?.isUsable == false ? repository.id : nil
      })
    let warnings = session.repositories.compactMap { repository -> String? in
      guard let verdict = verdicts[repository.id], let sentence = verdict.sentence(for: repository)
      else { return nil }
      return verdict.isUsable ? sentence : "\(sentence) The session starts without it."
    }

    do {
      let context = try SessionLaunchContext.make(
        for: session,
        worktreeRootPath: await root?.worktreeRootPath(),
        excluding: excluded
      )
      return (context, warnings)
    } catch .noRepository {
      throw SessionRestartRefusal.noRepository
    } catch .mainRepositoryUnavailable(let repository) {
      throw SessionRestartRefusal.mainRepositoryUnprepared(
        name: repository.displayName,
        reason: repository.failure?.message ?? "it has no folder to start in.")
    }
  }
}
