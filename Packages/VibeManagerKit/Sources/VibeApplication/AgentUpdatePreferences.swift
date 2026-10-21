import Foundation

/// Whether the sessions of an agent are restarted onto its updated CLI on their own, as soon as
/// nothing would be lost (#409). Off until the user turns it on, agent by agent.
@MainActor
public protocol AgentUpdatePreferences: AnyObject {
  func restartsAutomatically(_ provider: AgentProviderID) -> Bool
  func setRestartsAutomatically(_ restarts: Bool, for provider: AgentProviderID)
}

/// Kept for this run only. What a workspace assembled without the system around it uses.
@MainActor
public final class InMemoryAgentUpdatePreferences: AgentUpdatePreferences {
  private var automatic: Set<AgentProviderID>

  public init(automatic: Set<AgentProviderID> = []) {
    self.automatic = automatic
  }

  public func restartsAutomatically(_ provider: AgentProviderID) -> Bool {
    automatic.contains(provider)
  }

  public func setRestartsAutomatically(_ restarts: Bool, for provider: AgentProviderID) {
    if restarts { automatic.insert(provider) } else { automatic.remove(provider) }
  }
}
