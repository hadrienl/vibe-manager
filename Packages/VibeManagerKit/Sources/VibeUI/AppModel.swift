import Foundation
import Observation
import VibeApplication
import VibeDomain
import VibeTerminalUI

@MainActor
@Observable
public final class AppModel {
  public enum State: Equatable {
    case idle
    case loading
    case loaded([WorkSession])
    case failed(message: String, canRestoreBackup: Bool)
  }

  /// A failure that struck while something was already on screen.
  ///
  /// Kept apart from `State.failed`: that state is the whole screen, which is right for a first
  /// load that found nothing, and wrong for a refresh over a workspace the user is working in.
  public struct RefreshFailure: Equatable {
    public let message: String
    public let canRestoreBackup: Bool
  }

  public private(set) var state: State = .idle
  public private(set) var refreshFailure: RefreshFailure?
  public private(set) var agentDiagnostics: [AgentDiagnostic] = []
  public private(set) var isRefreshingAgents = false
  private var isReloading = false
  public private(set) var selectedSessionID: SessionID?
  public private(set) var isPresentingNewSession = false
  public private(set) var newSessionModel: NewSessionModel?

  private let repository: any SessionRepository
  private let loadSessions: LoadSessions
  private let recovery: (any SessionStoreRecovery)?
  private let agents: (any AgentProviderResolving)?
  private let launcher: SessionLauncher?
  private let defaultWorkingDirectoryPath: String?

  public init(
    repository: any SessionRepository,
    recovery: (any SessionStoreRecovery)? = nil,
    agents: (any AgentProviderResolving)? = nil,
    launcher: SessionLauncher? = nil,
    defaultWorkingDirectoryPath: String? = nil
  ) {
    self.repository = repository
    loadSessions = LoadSessions(repository: repository)
    self.recovery = recovery
    self.agents = agents
    self.launcher = launcher
    self.defaultWorkingDirectoryPath = defaultWorkingDirectoryPath
  }

  public var sessions: [WorkSession] {
    guard case .loaded(let sessions) = state else { return [] }
    return sessions
  }

  public var selectedSession: WorkSession? {
    sessions.first { $0.id == selectedSessionID }
  }

  public var canCreateSession: Bool {
    agents != nil && launcher != nil
  }

  public var newSessionDefaultWorkingDirectoryPath: String? {
    defaultWorkingDirectoryPath
  }

  public func load() async {
    guard state == .idle else { return }
    await reload()
    await refreshAgents()
  }

  /// Detection never fails the application: an unavailable agent is data, not an error.
  ///
  /// Each agent is published as its own detection lands, in registration order. Waiting for the
  /// whole set would hold every result behind the slowest one, and a CLI that answers none of its
  /// probes now costs three budgets and their retries: there is no reason for the agents that
  /// answered straight away to stay hidden for that long.
  public func refreshAgents(forceRefresh: Bool = false) async {
    guard let agents, !isRefreshingAgents else { return }

    isRefreshingAgents = true
    defer { isRefreshingAgents = false }

    let descriptors = await agents.descriptors()
    var diagnostics: [AgentProviderID: AgentDiagnostic] = [:]

    await withTaskGroup(of: (AgentProviderID, AgentAvailability?).self) { group in
      for descriptor in descriptors {
        group.addTask {
          guard let provider = await agents.provider(id: descriptor.id) else {
            return (descriptor.id, nil)
          }
          return (descriptor.id, await provider.availability(forceRefresh: forceRefresh))
        }
      }

      for await (id, availability) in group {
        guard let availability else { continue }
        diagnostics[id] = availability.diagnostic
        agentDiagnostics = descriptors.compactMap { diagnostics[$0.id] }
      }
    }
  }

  public func resolution(for session: WorkSession) async -> SessionAgentResolution {
    guard let agents else { return .unassigned }
    return await ResolveSessionAgent(registry: agents)(for: session)
  }

  public func select(_ id: SessionID?) {
    selectedSessionID = id
  }

  public func pane(for id: SessionID) -> TerminalPaneModel? {
    launcher?.pane(for: id)
  }

  public func launchFailure(for id: SessionID) -> TerminalPaneModel.Failure? {
    launcher?.failure(for: id)
  }

  /// The sheet's model lives here, not in the sheet: SwiftUI may evaluate the presentation
  /// closure more than once, and a draft must survive that without being typed twice.
  public func beginNewSession() {
    guard let agents, canCreateSession else { return }
    newSessionModel = NewSessionModel(
      create: CreateSession(repository: repository, agents: agents),
      registry: agents
    )
    isPresentingNewSession = true
  }

  /// Cancelling leaves nothing behind: no session, no process, and no draft either.
  public func cancelNewSession() {
    isPresentingNewSession = false
    newSessionModel = nil
  }

  /// The order the ticket asks for: the session is already stored, so it is published and
  /// selected first, and only then does anything get started. A launch that fails leaves a
  /// session the user can see and retry, never a disappearing one.
  ///
  /// It is published by inserting it rather than by reloading the store: the session is already
  /// written, so showing it is a fact and not a guess, and the workspace never has to go blank
  /// to display something the application already holds.
  public func complete(_ creation: SessionCreation) async {
    isPresentingNewSession = false
    newSessionModel = nil
    insert(creation.session)
    select(creation.session.id)
    guard let launcher else { return }
    await launcher.launch(session: creation.session, plan: creation.plan)
    await reload()
  }

  public func reload() async {
    guard !isReloading else { return }
    isReloading = true
    defer { isReloading = false }

    // A refresh over something already on screen never blanks it. The spinner belongs to the
    // first load, when there is genuinely nothing to show.
    if sessions.isEmpty {
      state = .loading
    }

    let previousSelection = selectedSessionID
    do {
      let sessions = try await loadSessions()
      state = .loaded(sessions)
      refreshFailure = nil
      selectedSessionID =
        sessions.contains { $0.id == previousSelection } ? previousSelection : sessions.first?.id
    } catch {
      await report(error)
    }
  }

  /// Dismisses the banner. The sessions on screen are the ones the application already holds,
  /// so there is nothing to reload before letting the user get back to work.
  public func dismissRefreshFailure() {
    refreshFailure = nil
  }

  private func insert(_ session: WorkSession) {
    var sessions = sessions.filter { $0.id != session.id }
    sessions.append(session)
    state = .loaded(
      sessions.sorted { lhs, rhs in
        if lhs.updatedAt == rhs.updatedAt {
          return lhs.id.description < rhs.id.description
        }
        return lhs.updatedAt > rhs.updatedAt
      }
    )
  }

  public func restoreBackup() async {
    guard let recovery else { return }

    do {
      try await recovery.restoreBackup()
    } catch {
      await report(error)
      return
    }
    await reload()
  }

  /// A store failure never takes the workspace away.
  ///
  /// With nothing on screen the failure *is* the screen — there is no other way to offer the
  /// backup. With sessions already listed, and possibly an agent running in one of them, it is
  /// a banner over them: a transient read error must not dismantle the terminals or lose the
  /// user's place.
  private func report(_ error: Error) async {
    let message = (error as? LocalizedError)?.errorDescription ?? "Unable to load work sessions."
    let canRestoreBackup = await recovery?.recoveryStatus() == .backupAvailable

    if sessions.isEmpty {
      state = .failed(message: message, canRestoreBackup: canRestoreBackup)
    } else {
      refreshFailure = RefreshFailure(message: message, canRestoreBackup: canRestoreBackup)
    }
  }
}
