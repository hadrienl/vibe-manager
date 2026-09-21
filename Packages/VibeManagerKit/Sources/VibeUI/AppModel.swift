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

  public private(set) var state: State = .idle
  public private(set) var agentDiagnostics: [AgentDiagnostic] = []
  public private(set) var isRefreshingAgents = false
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
  public func complete(_ creation: SessionCreation) async {
    isPresentingNewSession = false
    newSessionModel = nil
    await reload()
    select(creation.session.id)
    guard let launcher else { return }
    await launcher.launch(session: creation.session, plan: creation.plan)
    await reload()
  }

  public func reload() async {
    guard state != .loading else { return }

    let previousSelection = selectedSessionID
    state = .loading
    do {
      let sessions = try await loadSessions()
      state = .loaded(sessions)
      selectedSessionID =
        sessions.contains { $0.id == previousSelection } ? previousSelection : sessions.first?.id
    } catch {
      state = await failure(for: error)
    }
  }

  public func restoreBackup() async {
    guard let recovery else { return }

    do {
      try await recovery.restoreBackup()
    } catch {
      state = await failure(for: error)
      return
    }
    await reload()
  }

  private func failure(for error: Error) async -> State {
    .failed(
      message: (error as? LocalizedError)?.errorDescription ?? "Unable to load work sessions.",
      canRestoreBackup: await recovery?.recoveryStatus() == .backupAvailable
    )
  }
}
