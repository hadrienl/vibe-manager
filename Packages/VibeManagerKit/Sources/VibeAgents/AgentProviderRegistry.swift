import VibeApplication

public struct AgentProviderRegistry: Sendable {
  public let providers: [any AgentProvider]

  public init(providers: [any AgentProvider] = []) {
    self.providers = providers
  }
}
