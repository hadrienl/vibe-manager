/// How a Codex-based agent handles requests that need approval.
public enum CodexApprovalMode: String, Codable, Hashable, Sendable, CaseIterable {
  case manual
  case autoReview
}
