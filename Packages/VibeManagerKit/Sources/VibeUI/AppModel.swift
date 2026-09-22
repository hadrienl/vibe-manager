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
