import Foundation
import Observation
import VibeApplication
import VibeDomain

/// The Endpoints tab of the settings (#107): the model servers the user declared, their keys in the
/// keychain, their models and the test of one of them.
@MainActor
@Observable
public final class EndpointsSettingsModel {
  public private(set) var endpoints: [Endpoint] = []
  public private(set) var isLoaded = false
  /// Why the file could not be read or written, said once and kept until a save succeeds.
  public private(set) var storeError: String?
  /// Bumped when a key is written or removed: the keychain is not observable.
  public private(set) var secretsRevision = 0

  @ObservationIgnored private let repository: any EndpointRepository
  @ObservationIgnored private let secrets: any EndpointSecretStore
  @ObservationIgnored private let probing: any EndpointProbing
  @ObservationIgnored private let didSave: @MainActor () async -> Void

  public init(
    repository: any EndpointRepository,
    secrets: any EndpointSecretStore,
    probing: any EndpointProbing,
    didSave: @escaping @MainActor () async -> Void = {}
  ) {
    self.repository = repository
    self.secrets = secrets
    self.probing = probing
    self.didSave = didSave
  }

  public var fileURL: URL? { repository.fileURL }

  public func load() async {
    do {
      endpoints = try await repository.endpoints()
      storeError = nil
    } catch {
      storeError = error.localizedDescription
    }
    isLoaded = true
  }

  /// Saves the list, and registers the endpoints again as agents. `false` when the file refused.
  @discardableResult
  public func save(_ list: [Endpoint]) async -> Bool {
    let removed = Set(endpoints.map(\.id)).subtracting(list.map(\.id))
    do {
      try await repository.save(list)
    } catch {
      storeError = error.localizedDescription
      return false
    }
    endpoints = list
    storeError = nil
    // A deleted endpoint leaves no key behind.
    for id in removed { try? secrets.removeSecret(for: id) }
    if !removed.isEmpty { secretsRevision += 1 }
    await didSave()
    return true
  }

  // MARK: - Keys

  public func hasSecret(for id: EndpointID) -> Bool {
    _ = secretsRevision
    return secrets.hasSecret(for: id)
  }

  /// Written to the keychain at once: a key is never kept anywhere else, not even in the draft.
  public func setSecret(_ secret: String, for id: EndpointID) -> String? {
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    do {
      try secrets.setSecret(trimmed, for: id)
      secretsRevision += 1
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  public func removeSecret(for id: EndpointID) {
    try? secrets.removeSecret(for: id)
    secretsRevision += 1
  }

  /// The key to try an endpoint with: the one typed, or the one kept.
  private func secret(for endpoint: Endpoint, typed: String) -> String? {
    let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if !typed.isEmpty { return typed }
    return (try? secrets.secret(for: endpoint.id)) ?? nil
  }

  // MARK: - Talking to the endpoint

  public func discoverModels(for endpoint: Endpoint, typedSecret: String) async -> Result<
    [EndpointModel], EndpointDiscoveryError
  > {
    do {
      return .success(
        try await probing.discoverModels(
          for: endpoint, secret: secret(for: endpoint, typed: typedSecret)))
    } catch let error as EndpointDiscoveryError {
      return .failure(error)
    } catch {
      return .failure(.failed(.unreachable))
    }
  }

  public func test(_ endpoint: Endpoint, typedSecret: String, model: String) async
    -> EndpointTestReport
  {
    await probing.test(endpoint, secret: secret(for: endpoint, typed: typedSecret), model: model)
  }

  /// What is wrong with a custom endpoint's document, where; `nil` when it reads.
  public func customProtocolProblem(_ document: String) -> String? {
    probing.customProtocolProblem(document)
  }

  /// A document to start from: an API that streams its answer as JSON lines.
  public static let customProtocolExample = """
    {
      "schema": 1,
      "request": {
        "path": "chat",
        "body": {"model": "{{model}}", "system": "{{system}}", "messages": "{{messages:openai}}", "tools": "{{tools:openai}}", "stream": true}
      },
      "stream": {"format": "ndjson"},
      "events": [
        {"when": {"path": "type", "equals": "text"}, "text": "delta"},
        {"when": {"path": "type", "equals": "tool_call"}, "toolCall": {"id": "id", "name": "name", "arguments": "arguments"}},
        {"when": {"path": "type", "equals": "server_step"}, "serverStep": {"name": "tool", "input": "input", "output": "output"}},
        {"when": {"path": "type", "equals": "done"}, "usage": {"input": "usage.input_tokens", "output": "usage.output_tokens"}, "stop": true},
        {"when": {"path": "type", "equals": "error"}, "error": "message"}
      ],
      "models": {"path": "models", "list": "data", "id": "id", "name": "name"}
    }
    """

  /// Keeps the verdict of a test on the endpoint, where the list and the sheets read it.
  public func record(_ report: EndpointTestReport, for id: EndpointID) async {
    guard let index = endpoints.firstIndex(where: { $0.id == id }) else { return }
    var list = endpoints
    list[index].lastTest = EndpointTestOutcome(
      verdict: report.verdict, date: report.date, model: report.model)
    await save(list)
  }

  // MARK: - Starting points

  public struct Preset: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var wireProtocol: EndpointWireKind
    public var authentication: EndpointAuthenticationKind
    public var defaultParameters = ""

    public var endpoint: Endpoint {
      Endpoint(
        name: name, baseURL: baseURL, wireProtocol: wireProtocol, authentication: authentication,
        defaultParameters: defaultParameters)
    }
  }

  /// What the empty tab offers to start from: the URL, the protocol and the kind of key filled in.
  public static let presets: [Preset] = [
    Preset(
      id: "ollama", name: "Ollama", baseURL: "http://localhost:11434", wireProtocol: .messages,
      authentication: .none),
    Preset(
      id: "lmstudio", name: "LM Studio", baseURL: "http://localhost:1234/v1",
      wireProtocol: .chatCompletions, authentication: .none),
    Preset(
      id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
      wireProtocol: .chatCompletions, authentication: .bearer),
    Preset(
      id: "prisme", name: "Prisme.ai LLM Gateway",
      baseURL: "https://api.studio.prisme.ai/v2/workspaces/slug:llm-gateway/webhooks/v1",
      wireProtocol: .chatCompletions, authentication: .header(name: "x-prismeai-api-key"),
      // Not in the fields it documents, and not needed: it gives the usage after `[DONE]`.
      defaultParameters: #"{"stream_options": null}"#),
    Preset(
      id: "openai", name: "OpenAI-compatible", baseURL: "https://", wireProtocol: .chatCompletions,
      authentication: .bearer),
    Preset(
      id: "anthropic", name: "Anthropic-compatible", baseURL: "https://", wireProtocol: .messages,
      authentication: .header(name: "x-api-key")),
  ]
}
