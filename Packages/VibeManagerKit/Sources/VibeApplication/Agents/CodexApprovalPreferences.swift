import VibeDomain

/// Modes for native Codex and its additional accounts. Endpoints keep their own definition.
@MainActor
public protocol CodexApprovalPreferences: AnyObject, Sendable {
  func mode(for provider: AgentProviderID) -> CodexApprovalMode
  func setMode(_ mode: CodexApprovalMode, for provider: AgentProviderID)
}

@MainActor
public final class InMemoryCodexApprovalPreferences: CodexApprovalPreferences {
  private var modes: [AgentProviderID: CodexApprovalMode]

  public init(mode: CodexApprovalMode = .manual) {
    modes = [AgentProviderID("codex"): mode]
  }

  public func mode(for provider: AgentProviderID) -> CodexApprovalMode {
    modes[provider] ?? .manual
  }

  public func setMode(_ mode: CodexApprovalMode, for provider: AgentProviderID) {
    modes[provider] = mode
  }
}
