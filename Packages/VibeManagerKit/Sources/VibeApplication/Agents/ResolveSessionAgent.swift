import VibeDomain

public enum SessionAgentResolution: Hashable, Sendable {
  /// The session never recorded an agent, which is valid for historical data.
  case unassigned
  /// The provider that ran this session is not registered anymore.
  case unknownProvider(String)
  /// The provider exists but cannot run right now.
  case unavailable(AgentDiagnostic)
  case ready(descriptor: AgentDescriptor, availability: AgentAvailability)

  public var isResumable: Bool {
    if case .ready = self { return true }
    return false
  }
}

/// Answers "can this stored session be resumed?" without ever failing to load it.
public struct ResolveSessionAgent: Sendable {
  private let registry: any AgentProviderResolving

  public init(registry: any AgentProviderResolving) {
    self.registry = registry
  }

  public func callAsFunction(for session: WorkSession) async -> SessionAgentResolution {
    guard let configuration = session.agent else { return .unassigned }

    let id = AgentProviderID(configuration.providerID)
    guard let provider = await registry.provider(id: id) else {
      return .unknownProvider(configuration.providerID)
    }

    let availability = await provider.availability(forceRefresh: false)
    guard availability.isUsable else {
      return .unavailable(availability.diagnostic)
    }
    return .ready(descriptor: provider.descriptor, availability: availability)
  }
}
