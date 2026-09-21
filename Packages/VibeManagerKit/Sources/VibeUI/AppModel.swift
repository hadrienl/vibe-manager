import Foundation
import Observation
import VibeApplication
import VibeDomain

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
  /// Provider diagnostics in registration order. An empty list simply means no agent is
  /// registered, which is a displayable state and never an error.
  public private(set) var agentDiagnostics: [AgentDiagnostic] = []
  public private(set) var isRefreshingAgents = false

  private let loadSessions: LoadSessions
  private let recovery: (any SessionStoreRecovery)?
  private let agents: (any AgentProviderResolving)?

  public init(
    repository: any SessionRepository,
    recovery: (any SessionStoreRecovery)? = nil,
    agents: (any AgentProviderResolving)? = nil
  ) {
    loadSessions = LoadSessions(repository: repository)
    self.recovery = recovery
    self.agents = agents
  }

  public func load() async {
    guard state == .idle else { return }
    await reload()
    await refreshAgents()
  }

  /// Detection never fails the application: an unavailable agent is data, not an error.
  public func refreshAgents(forceRefresh: Bool = false) async {
    guard let agents, !isRefreshingAgents else { return }

    isRefreshingAgents = true
    defer { isRefreshingAgents = false }

    let availabilities = await agents.availabilities(forceRefresh: forceRefresh)
    agentDiagnostics = await agents.descriptors().compactMap { availabilities[$0.id]?.diagnostic }
  }

  /// Whether a stored session can be handed back to its agent.
  public func resolution(for session: WorkSession) async -> SessionAgentResolution {
    guard let agents else { return .unassigned }
    return await ResolveSessionAgent(registry: agents)(for: session)
  }

  /// Retries a load that failed; transient store failures are recoverable.
  public func reload() async {
    guard state != .loading else { return }

    state = .loading
    do {
      state = .loaded(try await loadSessions())
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
