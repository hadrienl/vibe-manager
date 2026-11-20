import VibeDomain

/// The approval mode of each native agent and account that offers one, under its identifier.
/// Endpoints keep their own definition.
///
/// None by default: the CLI's own setting — Codex's `config.toml`, Antigravity's `agentMode` —
/// then applies, untouched. Vibe Manager imposes Manual or Automatic only once the user chose it.
@MainActor
public protocol AgentApprovalPreferences: AnyObject, Sendable {
  func mode(for provider: AgentProviderID) -> AgentApprovalMode?
  /// Nil goes back to the CLI's own setting.
  func setMode(_ mode: AgentApprovalMode?, for provider: AgentProviderID)
}

@MainActor
public final class InMemoryAgentApprovalPreferences: AgentApprovalPreferences {
  private var modes: [AgentProviderID: AgentApprovalMode]

  public init(
    mode: AgentApprovalMode? = nil, provider: AgentProviderID = AgentProviderID("codex")
  ) {
    modes = [:]
    modes[provider] = mode
  }

  public func mode(for provider: AgentProviderID) -> AgentApprovalMode? {
    modes[provider]
  }

  public func setMode(_ mode: AgentApprovalMode?, for provider: AgentProviderID) {
    modes[provider] = mode
  }
}
