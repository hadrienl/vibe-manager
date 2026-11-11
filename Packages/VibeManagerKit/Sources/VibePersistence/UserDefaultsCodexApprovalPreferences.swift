import Foundation
import VibeApplication
import VibeDomain

@MainActor
public final class UserDefaultsCodexApprovalPreferences: CodexApprovalPreferences {
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public func mode(for provider: AgentProviderID) -> CodexApprovalMode {
    defaults.string(forKey: key(provider)).flatMap(CodexApprovalMode.init(rawValue:)) ?? .manual
  }

  public func setMode(_ mode: CodexApprovalMode, for provider: AgentProviderID) {
    defaults.set(mode.rawValue, forKey: key(provider))
  }

  private func key(_ provider: AgentProviderID) -> String {
    "codex.approvalMode.\(provider.rawValue).v1"
  }
}
