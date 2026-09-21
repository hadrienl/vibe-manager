import Foundation
import VibeApplication

/// Holds the known providers in a stable order and aggregates their availability.
///
/// Registering a provider is the only step needed to add an agent: no view, use case or
/// persisted model has to change.
public actor AgentProviderRegistry: AgentProviderResolving {
  private let ordered: [any AgentProvider]
  private let index: [AgentProviderID: any AgentProvider]

  public init(providers: [any AgentProvider] = []) {
    var ordered: [any AgentProvider] = []
    var index: [AgentProviderID: any AgentProvider] = [:]
    for provider in providers where index[provider.descriptor.id] == nil {
      index[provider.descriptor.id] = provider
      ordered.append(provider)
    }
    self.ordered = ordered
    self.index = index
  }

  public func providers() -> [any AgentProvider] {
    ordered
  }

  public func descriptors() -> [AgentDescriptor] {
    ordered.map(\.descriptor)
  }

  public func provider(id: AgentProviderID) -> (any AgentProvider)? {
    index[id]
  }

  /// Probes every provider concurrently: one slow CLI never delays the others.
  public func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
    await withTaskGroup(of: (AgentProviderID, AgentAvailability).self) { group in
      for provider in ordered {
        group.addTask {
          (provider.descriptor.id, await provider.availability(forceRefresh: forceRefresh))
        }
      }

      var results: [AgentProviderID: AgentAvailability] = [:]
      for await (id, availability) in group {
        results[id] = availability
      }
      return results
    }
  }

  /// Diagnostics in registration order, ready to be displayed or exported.
  public func diagnostics(forceRefresh: Bool = false) async -> [AgentDiagnostic] {
    let availabilities = await availabilities(forceRefresh: forceRefresh)
    return ordered.compactMap { availabilities[$0.descriptor.id]?.diagnostic }
  }
}
