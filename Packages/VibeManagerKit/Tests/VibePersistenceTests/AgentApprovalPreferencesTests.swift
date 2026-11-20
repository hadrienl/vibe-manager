import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@MainActor
@Suite("Agent approval preferences")
struct AgentApprovalPreferencesTests {
  @Test("The CLI's own setting by default, a choice persists and can be taken back")
  func persistence() throws {
    let suite = "codex-approval-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = UserDefaultsAgentApprovalPreferences(suiteName: suite)
    let codex = AgentProviderID("codex")
    #expect(preferences.mode(for: codex) == nil)
    preferences.setMode(.autoReview, for: codex)
    #expect(UserDefaultsAgentApprovalPreferences(suiteName: suite).mode(for: codex) == .autoReview)
    let account = AgentProviderID("account.codex-test")
    #expect(preferences.mode(for: account) == nil)
    preferences.setMode(.autoReview, for: account)
    preferences.setMode(.manual, for: codex)
    #expect(UserDefaultsAgentApprovalPreferences(suiteName: suite).mode(for: codex) == .manual)
    #expect(
      UserDefaultsAgentApprovalPreferences(suiteName: suite).mode(for: account) == .autoReview)
    preferences.setMode(nil, for: codex)
    #expect(UserDefaultsAgentApprovalPreferences(suiteName: suite).mode(for: codex) == nil)
  }

  @Test(
    "One store: Antigravity persists independently of Codex, leaves the CLI's setting by default and tolerates unknown values"
  )
  func antigravityPersistence() throws {
    let suite = "antigravity-approval-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let agy = AgentProviderID("antigravity")
    let codex = AgentProviderID("codex")
    let preferences = UserDefaultsAgentApprovalPreferences(suiteName: suite)
    let codexPreferences = UserDefaultsAgentApprovalPreferences(suiteName: suite)
    #expect(preferences.mode(for: agy) == nil)
    codexPreferences.setMode(.autoReview, for: codex)
    #expect(preferences.mode(for: agy) == nil)
    preferences.setMode(.autoReview, for: agy)
    let reloaded = UserDefaultsAgentApprovalPreferences(suiteName: suite)
    #expect(reloaded.mode(for: agy) == .autoReview)
    #expect(reloaded.mode(for: AgentProviderID("account.future-agy")) == nil)
    reloaded.setMode(.manual, for: agy)
    #expect(preferences.mode(for: agy) == .manual)
    #expect(codexPreferences.mode(for: codex) == .autoReview)
    defaults.set("future-mode", forKey: "codex.approvalMode.antigravity.v1")
    #expect(preferences.mode(for: agy) == nil)
    // #543's keys and raw values must survive the shared-type extraction unchanged.
    #expect(defaults.string(forKey: "codex.approvalMode.codex.v1") == "autoReview")
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
