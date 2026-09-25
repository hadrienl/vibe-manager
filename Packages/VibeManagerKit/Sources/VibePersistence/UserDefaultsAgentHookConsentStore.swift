import Foundation
import VibeApplication

/// Whether the user let Vibe Manager approve a CLI's activity hooks, kept across launches (#45).
///
/// In the user defaults rather than next to the sessions: it is a preference, which the Settings
/// window changes and a copy of the application with its own data folder shares.
public final class UserDefaultsAgentHookConsentStore: AgentHookConsentStore, @unchecked Sendable {
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public func approvedFingerprint(for provider: AgentProviderID) -> String? {
    defaults.string(forKey: fingerprintKey(provider))
  }

  public func setApprovedFingerprint(_ fingerprint: String?, for provider: AgentProviderID) {
    defaults.set(fingerprint, forKey: fingerprintKey(provider))
  }

  public func isDeclined(_ provider: AgentProviderID) -> Bool {
    defaults.bool(forKey: declinedKey(provider))
  }

  public func setDeclined(_ declined: Bool, for provider: AgentProviderID) {
    defaults.set(declined, forKey: declinedKey(provider))
  }

  private func fingerprintKey(_ provider: AgentProviderID) -> String {
    "agentActivity.\(provider.rawValue).approvedHooks.v1"
  }

  private func declinedKey(_ provider: AgentProviderID) -> String {
    "agentActivity.\(provider.rawValue).declined.v1"
  }
}
