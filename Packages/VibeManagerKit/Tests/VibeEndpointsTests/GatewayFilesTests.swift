import Foundation
import Testing
import VibeDomain

@testable import VibeEndpoints

@Suite("The gateway's files")
struct GatewayFilesTests {
  private func location() throws -> GatewayLocation {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeGateway-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return GatewayLocation(
      directory: folder.appendingPathComponent("Gateway", isDirectory: true),
      endpointsURL: folder.appendingPathComponent("endpoints.json"))
  }

  private func writeEndpoints(_ endpoints: [Endpoint], to url: URL) throws {
    struct Stored: Codable {
      var schema = 1
      var endpoints: [Endpoint]
    }
    try JSONEncoder().encode(Stored(endpoints: endpoints)).write(to: url)
  }

  private func readEndpoints(_ url: URL) throws -> [Endpoint] {
    struct Stored: Codable {
      var endpoints: [Endpoint]
    }
    guard let data = try? Data(contentsOf: url) else { return [] }
    return try JSONDecoder().decode(Stored.self, from: data).endpoints
  }

  @Test("A token leads to its endpoint and model, with the secret read at that moment")
  func routes() async throws {
    let location = try location()
    defer {
      try? FileManager.default.removeItem(at: location.directory.deletingLastPathComponent())
    }
    let endpoint = Endpoint(
      name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", wireProtocol: .chatCompletions,
      defaultParameters: #"{"provider":{"sort":"price"}}"#)
    try writeEndpoints([endpoint], to: location.endpointsURL)
    let controller = EndpointGatewayController(location: location, launch: {})
    let session = SessionID()
    try await controller.register(
      token: "t1", endpoint: endpoint.id, model: "qwen", session: session)

    let secret = SecretBox("sk-1")
    let router = FileGatewayRouter(
      location: location, readEndpoints: { try self.readEndpoints($0) },
      secret: { _ in secret.value })
    let route = try #require(await router.route(for: "t1"))
    #expect(route.model == "qwen")
    #expect(route.secret == "sk-1")
    #expect(route.endpoint.wireProtocol == .chatCompletions)
    #expect(route.endpoint.defaultParameters["provider"] == ["sort": "price"])
    #expect(await router.route(for: "nope") == nil)

    // A new launch of the same session replaces its token; the change is seen without restarting.
    try await Task.sleep(for: .milliseconds(20))
    try await controller.register(
      token: "t2", endpoint: endpoint.id, model: "qwen", session: session)
    #expect(await router.route(for: "t1") == nil)
    #expect(await router.route(for: "t2") != nil)
    secret.value = "sk-2"
    #expect(await router.route(for: "t2")?.secret == "sk-2")

    // Ended sessions let go of their tokens, and the gateway is left with none.
    try await controller.retain(sessions: [])
    #expect(await router.count() == 0)
    let attributes = try FileManager.default.attributesOfItem(atPath: location.routesURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test("Tokens are 256 random bits")
  func tokens() {
    let token = EndpointGatewayController.makeToken()
    #expect(token.count == 64)
    #expect(token != EndpointGatewayController.makeToken())
  }

  @Test("The gateway starts, answers on its port, refuses a second one, and stops when idle")
  func service() async throws {
    let location = try location()
    defer {
      try? FileManager.default.removeItem(at: location.directory.deletingLastPathComponent())
    }
    let router = FileGatewayRouter(
      location: location, readEndpoints: { _ in [] }, secret: { _ in nil })
    try location.prepare()
    try GatewayRoutesDocument(
      routes: [
        "t": .init(endpoint: EndpointID(), model: "m", session: nil, createdAt: Date())
      ]
    ).write(to: location.routesURL)
    let running = Task {
      try await EndpointGatewayService.run(
        location: location, router: router, transport: ScriptedTransport([]),
        idleCheck: .milliseconds(50), idleChecksBeforeExit: 2)
    }
    var state: GatewayState?
    for _ in 0..<100 where state == nil {
      try await Task.sleep(for: .milliseconds(20))
      state = GatewayState.read(location.stateURL)
    }
    let port = try #require(state?.port)
    #expect(port > 0)
    let second = try await EndpointGatewayService.run(
      location: location, router: router, transport: ScriptedTransport([]))
    #expect(second == .alreadyRunning)

    var request = URLRequest(
      url: try #require(URL(string: "http://127.0.0.1:\(port)/s/t/v1/models")))
    request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
    let (_, response) = try await URLSession.shared.data(for: request)
    // The token leads to an endpoint that no longer exists: refused, but by the gateway.
    #expect((response as? HTTPURLResponse)?.statusCode == 401)

    try GatewayRoutesDocument().write(to: location.routesURL)
    #expect(try await running.value == .idle)
    #expect(GatewayState.read(location.stateURL) == nil)
  }
}

final class SecretBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: String?

  init(_ value: String?) { stored = value }

  var value: String? {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

@Suite("An endpoint's models")
struct ModelDiscoveryTests {
  @Test("OpenAI's list, with what OpenRouter adds to it")
  func openRouter() throws {
    let models = EndpointProber.models(
      in: try JSONValue(
        parsing:
          #"{"data":[{"id":"qwen/qwen3-coder","name":"Qwen3 Coder","context_length":262144,"supported_parameters":["tools","tool_choice"],"architecture":{"input_modalities":["text"]},"pricing":{"prompt":"0.00000022","completion":"0.00000095"}},{"id":"tiny","supported_parameters":["temperature"]}]}"#
      ))
    #expect(models.map(\.id) == ["qwen/qwen3-coder", "tiny"])
    #expect(models[0].contextWindow == 262_144)
    #expect(models[0].supportsTools)
    #expect(abs((models[0].inputPricePerMillion ?? 0) - 0.22) < 0.0001)
    #expect(!models[1].supportsTools)
  }

  @Test("The Prisme.ai LLM Gateway's catalogue: completion models only, hidden ones left out")
  func prismeCatalogue() throws {
    let models = EndpointProber.models(
      in: try JSONValue(
        parsing:
          #"{"items":[{"model_id":"claude-sonnet","type":"completion","display":{"name":"Claude Sonnet"},"capabilities":{"vision":true},"limits":{"context_window":200000},"pricing":{"input_per_1m_tokens":3,"output_per_1m_tokens":15}},{"model_id":"embed","type":"embeddings"},{"model_id":"old","type":"completion","display":{"hidden":true}}],"total":3,"page":0,"limit":100}"#
      ))
    #expect(models.map(\.id) == ["claude-sonnet"])
    #expect(models[0].displayName == "Claude Sonnet")
    #expect(models[0].contextWindow == 200_000)
    #expect(models[0].supportsVision)
    #expect(models[0].outputPricePerMillion == 15)
  }

  @Test("Anthropic's list, and nothing readable is no list")
  func anthropic() throws {
    let models = EndpointProber.models(
      in: try JSONValue(parsing: #"{"data":[{"id":"claude-x","display_name":"Claude X"}]}"#))
    #expect(models.first?.displayName == "Claude X")
    #expect(EndpointProber.models(in: try JSONValue(parsing: #"{"ok":true}"#)).isEmpty)
  }
}
