import Foundation
import VibeApplication
import VibeDomain

@MainActor
public final class UserDefaultsAgentApprovalPreferences: AgentApprovalPreferences {
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  /// Nil when never chosen: the CLI's own setting.
  public func mode(for provider: AgentProviderID) -> AgentApprovalMode? {
    defaults.string(forKey: key(provider)).flatMap(AgentApprovalMode.init(rawValue:))
  }

  public func setMode(_ mode: AgentApprovalMode?, for provider: AgentProviderID) {
    if let mode {
      defaults.set(mode.rawValue, forKey: key(provider))
    } else {
      defaults.removeObject(forKey: key(provider))
    }
  }

  /// The `codex.` prefix is #543's, when Codex alone had a mode: kept, so that the choices already
  /// saved are still read. Identifiers are unique across agents, so one scheme serves them all.
  private func key(_ provider: AgentProviderID) -> String {
    "codex.approvalMode.\(provider.rawValue).v1"
  }
}
