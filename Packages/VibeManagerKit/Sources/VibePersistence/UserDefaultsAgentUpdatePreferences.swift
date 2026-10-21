import Foundation
import VibeApplication

/// The automatic restart onto an updated CLI (#409), kept across launches, one key per agent.
@MainActor
public final class UserDefaultsAgentUpdatePreferences: AgentUpdatePreferences {
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public func restartsAutomatically(_ provider: AgentProviderID) -> Bool {
    defaults.bool(forKey: key(provider))
  }

  public func setRestartsAutomatically(_ restarts: Bool, for provider: AgentProviderID) {
    defaults.set(restarts, forKey: key(provider))
  }

  private func key(_ provider: AgentProviderID) -> String {
    "agentUpdate.\(provider.rawValue).restartsAutomatically.v1"
  }
}
