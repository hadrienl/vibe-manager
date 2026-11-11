import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@MainActor
@Suite("Codex approval preferences")
struct CodexApprovalPreferencesTests {
  @Test("Manual by default, a choice persists and can be turned off")
  func persistence() throws {
    let suite = "codex-approval-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = UserDefaultsCodexApprovalPreferences(suiteName: suite)
    let codex = AgentProviderID("codex")
    #expect(preferences.mode(for: codex) == .manual)
    preferences.setMode(.autoReview, for: codex)
    #expect(UserDefaultsCodexApprovalPreferences(suiteName: suite).mode(for: codex) == .autoReview)
    let account = AgentProviderID("account.codex-test")
    #expect(preferences.mode(for: account) == .manual)
    preferences.setMode(.autoReview, for: account)
    preferences.setMode(.manual, for: codex)
    #expect(UserDefaultsCodexApprovalPreferences(suiteName: suite).mode(for: codex) == .manual)
    #expect(
      UserDefaultsCodexApprovalPreferences(suiteName: suite).mode(for: account) == .autoReview)
  }

  @Test("Existing endpoints stay manual; an endpoint's auto mode survives a round trip")
  func endpointMigration() throws {
    let endpoint = Endpoint(
      name: "Codex endpoint", baseURL: "http://localhost/v1", wireProtocol: .responses,
      codexApprovalMode: .autoReview)
    let encoded = try JSONEncoder().encode(endpoint)
    #expect(try JSONDecoder().decode(Endpoint.self, from: encoded).codexApprovalMode == .autoReview)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "codexApprovalMode")
    let old = try JSONSerialization.data(withJSONObject: legacy)
    #expect(try JSONDecoder().decode(Endpoint.self, from: old).codexApprovalMode == .manual)
  }
}
