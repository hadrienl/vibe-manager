import Foundation
import Testing

@testable import VibeDomain

@Suite("An endpoint's settings")
struct EndpointTests {
  private func endpoint(
    url: String = "https://openrouter.ai/api/v1", name: String = "OpenRouter",
    authentication: EndpointAuthenticationKind = .bearer, parameters: String = "",
    models: [EndpointModel] = [EndpointModel(id: "qwen/qwen3-coder")]
  ) -> Endpoint {
    Endpoint(
      name: name, baseURL: url, wireProtocol: .chatCompletions, authentication: authentication,
      defaultParameters: parameters, models: models)
  }

  @Test("A complete endpoint has nothing to fix")
  func complete() {
    #expect(endpoint().validationIssues.isEmpty)
    #expect(endpoint(url: "http://localhost:11434").validationIssues.isEmpty)
    #expect(endpoint(url: "http://192.168.1.20:1234/v1").validationIssues.isEmpty)
    #expect(endpoint(url: "http://mac-studio.local:11434").validationIssues.isEmpty)
  }

  @Test("Each missing piece is named, plain HTTP beyond the local network included")
  func issues() {
    #expect(endpoint(name: "  ").validationIssues == [.missingName])
    #expect(endpoint(url: "openrouter.ai").validationIssues == [.invalidURL])
    #expect(endpoint(url: "http://llm.example.com/v1").validationIssues == [.insecureURL])
    #expect(
      endpoint(authentication: .header(name: " ")).validationIssues == [.missingAuthenticationName])
    #expect(endpoint(parameters: "[1]").validationIssues == [.invalidParameters])
    #expect(endpoint(parameters: #"{"provider":{"sort":"price"}}"#).validationIssues.isEmpty)
    #expect(
      endpoint(models: [EndpointModel(id: "tiny", supportsTools: false)]).validationIssues
        == [.noToolModel])
  }

  @Test("Its agent identifier reads back, and only the host is shown in diagnostics")
  func identifiers() {
    let endpoint = endpoint(url: "https://user:key@llm.corp.example/v1?key=secret")
    #expect(EndpointID(providerID: endpoint.providerID) == endpoint.id)
    #expect(EndpointID(providerID: "claude-code") == nil)
    #expect(endpoint.redactedHost == "llm.corp.example")
  }

  @Test("Short contexts are flagged; stored endpoints decode as they were written")
  func modelsAndCoding() throws {
    #expect(EndpointModel(id: "a", contextWindow: 8_192).hasShortContext)
    #expect(!EndpointModel(id: "a", contextWindow: 65_536).hasShortContext)
    #expect(!EndpointModel(id: "a").hasShortContext)
    var original = endpoint(authentication: .query(name: "key"))
    original.headers = [EndpointHeader(name: "X-Title", value: "Vibe Manager")]
    original.harness = .codex
    original.lastTest = EndpointTestOutcome(
      verdict: .passedWithWarnings, date: Date(timeIntervalSince1970: 7))
    let decoded = try JSONDecoder().decode(Endpoint.self, from: JSONEncoder().encode(original))
    #expect(decoded == original)
  }
}
