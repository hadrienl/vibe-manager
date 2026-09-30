import Foundation
import VibeApplication
import VibeDomain

/// Lists an endpoint's models and tests one of them, straight from the application: nothing goes
/// through the gateway, which only serves sessions.
public struct EndpointProber: EndpointProbing {
  private let transport: any EndpointTransport
  private let clock = ContinuousClock()

  public init(transport: any EndpointTransport) {
    self.transport = transport
  }

  // MARK: - Models

  public func discoverModels(for endpoint: Endpoint, secret: String?) async throws
    -> [EndpointModel]
  {
    guard let configuration = EndpointConfiguration(endpoint) else {
      throw EndpointDiscoveryError.failed(.unreachable)
    }
    if let document = configuration.customProtocol {
      guard let models = document.models else { throw EndpointDiscoveryError.noList }
      let body = try await get(
        configuration.url(for: models.path, secret: secret), configuration: configuration,
        secret: secret)
      let list = models.list.components.isEmpty ? body : models.list.value(in: body)
      let found = (list?.arrayValue ?? []).compactMap { item -> EndpointModel? in
        guard let id = models.id.string(in: item) else { return nil }
        return EndpointModel(id: id, displayName: models.name.flatMap { $0.string(in: item) })
      }
      guard !found.isEmpty else { throw EndpointDiscoveryError.noList }
      return found
    }
    let operation = endpoint.wireProtocol == .messages ? "v1/models" : "models"
    let url: URL
    if endpoint.wireProtocol == .messages, configuration.messagesOperation == "messages" {
      url = configuration.url(for: "models", secret: secret)
    } else {
      url = configuration.url(for: operation, secret: secret)
    }
    let body = try await get(url, configuration: configuration, secret: secret)
    var models = Self.models(in: body)
    guard !models.isEmpty else { throw EndpointDiscoveryError.noList }
    // Ollama says more about each model on its own route: what it can do, and the context it was
    // given. Asked only of a server that answers it.
    if let enriched = await ollamaDetails(for: models, configuration: configuration) {
      models = enriched
    }
    return models
  }

  private func get(_ url: URL, configuration: EndpointConfiguration, secret: String?) async throws
    -> JSONValue
  {
    var headers = configuration.requestHeaders(secret: secret)
    headers["accept"] = "application/json"
    if configuration.wireProtocol == .messages { headers["anthropic-version"] = "2023-06-01" }
    let response: EndpointHTTPResponse
    do {
      response = try await transport.send(
        EndpointHTTPRequest(url: url, method: "GET", headers: headers),
        timeouts: EndpointTimeouts(
          connect: .seconds(10), firstByte: .seconds(20), idle: .seconds(20), total: .seconds(30)))
    } catch let failure as EndpointFailure {
      throw EndpointDiscoveryError.failed(Self.detail(for: failure.redacting(secret)))
    }
    let data = try await response.collect(limit: 16 * 1_024 * 1_024)
    guard (200..<300).contains(response.status) else {
      throw EndpointDiscoveryError.failed(
        Self.detail(
          for: EndpointFailure.http(status: response.status, body: data, retryAfter: nil)
            .redacting(secret)))
    }
    guard let json = try? JSONValue(parsing: data) else { throw EndpointDiscoveryError.noList }
    return json
  }

  /// The model lists endpoints answer: OpenAI's `data`, with what OpenRouter adds to it,
  /// Anthropic's, and the Prisme.ai LLM Gateway's catalogue in `items`.
  static func models(in body: JSONValue) -> [EndpointModel] {
    var result: [EndpointModel] = []
    for item in body["data"]?.arrayValue ?? [] {
      guard let id = item["id"]?.stringValue else { continue }
      let parameters = item["supported_parameters"]?.arrayValue?.compactMap(\.stringValue)
      let inputs = item["architecture"]?["input_modalities"]?.arrayValue?.compactMap(\.stringValue)
      let pricing = item["pricing"]
      result.append(
        EndpointModel(
          id: id,
          displayName: item["display_name"]?.stringValue ?? item["name"]?.stringValue,
          contextWindow: item["context_length"]?.intValue
            ?? item["top_provider"]?["context_length"]?.intValue
            ?? item["max_input_tokens"]?.intValue,
          // Unknown means yes: most servers do not say, and a model that cannot is found by Test.
          supportsTools: parameters.map { $0.contains("tools") } ?? true,
          supportsVision: inputs?.contains("image") ?? false,
          supportsReasoning: parameters?.contains("reasoning") ?? false,
          inputPricePerMillion: pricing?["prompt"]?.stringValue.flatMap(Double.init).map {
            $0 * 1_000_000
          },
          outputPricePerMillion: pricing?["completion"]?.stringValue.flatMap(Double.init).map {
            $0 * 1_000_000
          }))
    }
    for item in body["items"]?.arrayValue ?? [] {
      guard let id = item["model_id"]?.stringValue ?? item["id"]?.stringValue else { continue }
      if let type = item["type"]?.stringValue, type != "completion" { continue }
      if item["display"]?["hidden"]?.boolValue == true || item["enabled"]?.boolValue == false {
        continue
      }
      let limits = item["limits"]?.objectValue ?? [:]
      let context = limits.first { $0.key.lowercased().contains("context") }?.value.intValue
      result.append(
        EndpointModel(
          id: id,
          displayName: item["display"]?["name"]?.stringValue,
          contextWindow: context,
          supportsTools: true,
          supportsVision: item["capabilities"]?["vision"]?.boolValue ?? false,
          inputPricePerMillion: item["pricing"]?["input_per_1m_tokens"]?.numberValue,
          outputPricePerMillion: item["pricing"]?["output_per_1m_tokens"]?.numberValue))
    }
    for item in body["models"]?.arrayValue ?? [] where result.isEmpty {
      guard let id = item["model"]?.stringValue ?? item["name"]?.stringValue else { continue }
      result.append(EndpointModel(id: id))
    }
    return result
  }

  private func ollamaDetails(
    for models: [EndpointModel], configuration: EndpointConfiguration
  ) async -> [EndpointModel]? {
    guard var root = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
    else { return nil }
    root.path = "/api/show"
    root.query = nil
    guard let url = root.url else { return nil }
    var enriched: [EndpointModel] = []
    for model in models {
      let request = EndpointHTTPRequest(
        url: url, headers: ["content-type": "application/json"],
        body: JSONValue.object(["model": .string(model.id)]).data())
      guard
        let response = try? await transport.send(
          request,
          timeouts: EndpointTimeouts(
            connect: .seconds(3), firstByte: .seconds(10), idle: .seconds(10), total: .seconds(15))),
        response.status == 200, let data = try? await response.collect(),
        let body = try? JSONValue(parsing: data)
      else { return enriched.isEmpty ? nil : enriched + models.dropFirst(enriched.count) }
      var model = model
      let capabilities = body["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? []
      if !capabilities.isEmpty {
        model.supportsTools = capabilities.contains("tools")
        model.supportsVision = capabilities.contains("vision")
        model.supportsReasoning = capabilities.contains("thinking")
      }
      // The context the server runs the model with, when it was set; not what it was trained on.
      if let parameters = body["parameters"]?.stringValue,
        let line = parameters.split(separator: "\n").first(where: { $0.hasPrefix("num_ctx") }),
        let value = line.split(whereSeparator: \.isWhitespace).last.flatMap({ Int($0) })
      {
        model.contextWindow = value
      }
      enriched.append(model)
    }
    return enriched
  }

  public func customProtocolProblem(_ document: String) -> String? {
    do {
      _ = try CustomProtocolDocument(parsing: document)
      return nil
    } catch let error as CustomProtocolError {
      return error.description
    } catch {
      return "document: does not read"
    }
  }

  // MARK: - Test

  static let echoTool = CanonicalTool(
    name: "vibe_echo",
    description: "Repeats the given text. Call it when asked to.",
    inputSchema: [
      "type": "object",
      "properties": ["text": ["type": "string", "description": "The text to repeat."]],
      "required": ["text"],
    ])

  public func test(_ endpoint: Endpoint, secret: String?, model: String) async
    -> EndpointTestReport
  {
    var checks: [EndpointTestCheck] = []
    func skipRest(after kinds: [EndpointTestCheck.Kind]) -> EndpointTestReport {
      for kind in EndpointTestCheck.Kind.allCases where !kinds.contains(kind) {
        if !checks.contains(where: { $0.kind == kind }) {
          checks.append(EndpointTestCheck(kind: kind, outcome: .skipped))
        }
      }
      return EndpointTestReport(model: model, date: Date(), checks: checks)
    }
    guard let configuration = EndpointConfiguration(endpoint) else {
      checks.append(EndpointTestCheck(kind: .reachable, outcome: .failed, detail: .unreachable))
      return skipRest(after: [.reachable])
    }
    let route = GatewayRoute(endpoint: configuration, secret: secret, model: model)
    let question = CanonicalRequest(
      model: model,
      system: "You are testing a connection. Follow the instruction exactly.",
      messages: [
        CanonicalMessage(
          role: .user,
          content: [
            .text("Call the vibe_echo tool with the text \"ping\". Do not answer otherwise.")
          ])
      ],
      tools: [Self.echoTool], maxOutputTokens: 512)

    // One turn: reach, authenticate, answer with a call.
    let started = clock.now
    let first: Collected
    do {
      first = try await collect(question, route: route)
    } catch let failure as EndpointFailure {
      switch failure.kind {
      case .network:
        checks.append(EndpointTestCheck(kind: .reachable, outcome: .failed, detail: .unreachable))
        return skipRest(after: [.reachable])
      case .timeout:
        checks.append(EndpointTestCheck(kind: .reachable, outcome: .failed, detail: .timedOut))
        return skipRest(after: [.reachable])
      case .authentication, .permission:
        checks.append(EndpointTestCheck(kind: .reachable, outcome: .passed))
        checks.append(
          EndpointTestCheck(
            kind: .authentication, outcome: .failed, detail: Self.detail(for: failure.redacting(secret))))
        return skipRest(after: [.reachable, .authentication])
      default:
        checks.append(EndpointTestCheck(kind: .reachable, outcome: .passed))
        checks.append(EndpointTestCheck(kind: .authentication, outcome: .passed))
        checks.append(
          EndpointTestCheck(kind: .answer, outcome: .failed, detail: Self.detail(for: failure.redacting(secret))))
        return skipRest(after: [.reachable, .authentication, .answer])
      }
    } catch {
      checks.append(EndpointTestCheck(kind: .reachable, outcome: .failed, detail: .unreachable))
      return skipRest(after: [.reachable])
    }
    checks.append(
      EndpointTestCheck(
        kind: .reachable, outcome: .passed,
        detail: .latency(milliseconds: Self.milliseconds(first.firstEvent - started))))
    checks.append(EndpointTestCheck(kind: .authentication, outcome: .passed))
    let tokensPerSecond = first.usage.flatMap { usage -> Double? in
      let seconds =
        Double((first.end - first.firstEvent).components.seconds)
        + Double((first.end - first.firstEvent).components.attoseconds) / 1e18
      return seconds > 0.05 && usage.outputTokens > 0 ? Double(usage.outputTokens) / seconds : nil
    }
    checks.append(
      EndpointTestCheck(
        kind: .answer, outcome: .passed,
        detail: first.serverSteps > 0
          ? .serverSteps(count: first.serverSteps)
          : .speed(
            firstTokenMilliseconds: Self.milliseconds(first.firstEvent - started),
            tokensPerSecond: tokensPerSecond)))

    guard
      let call = first.response.content.compactMap({ block -> (String, String)? in
        if case .toolCall(let id, let name, let arguments) = block, name == Self.echoTool.name {
          return (id, arguments)
        }
        return nil
      }).first
    else {
      checks.append(EndpointTestCheck(kind: .toolCall, outcome: .failed, detail: .noToolCall))
      checks.append(usageCheck(first.usage))
      return skipRest(after: [.reachable, .authentication, .answer, .toolCall, .usage])
    }
    guard (try? JSONValue(parsing: call.1))?["text"]?.stringValue != nil else {
      checks.append(EndpointTestCheck(kind: .toolCall, outcome: .failed, detail: .invalidArguments))
      checks.append(usageCheck(first.usage))
      return skipRest(after: [.reachable, .authentication, .answer, .toolCall, .usage])
    }
    checks.append(EndpointTestCheck(kind: .toolCall, outcome: .passed))

    // A second turn: the result given back, and an answer after it.
    var followUp = question
    followUp.messages.append(CanonicalMessage(role: .assistant, content: first.response.content))
    followUp.messages.append(
      CanonicalMessage(
        role: .user,
        content: [.toolResult(callID: call.0, content: [.text("ping")], isError: false)]))
    do {
      let second = try await collect(followUp, route: route)
      let answered = second.response.content.contains {
        if case .text(let text) = $0 { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
        if case .toolCall = $0 { return true }
        return false
      }
      checks.append(
        EndpointTestCheck(
          kind: .toolResult, outcome: answered ? .passed : .warning,
          detail: answered ? nil : .noAnswerAfterTool))
    } catch let failure as EndpointFailure {
      checks.append(
        EndpointTestCheck(kind: .toolResult, outcome: .failed, detail: Self.detail(for: failure.redacting(secret))))
    } catch {
      checks.append(EndpointTestCheck(kind: .toolResult, outcome: .failed, detail: .unreachable))
    }
    checks.append(usageCheck(first.usage))
    return EndpointTestReport(model: model, date: Date(), checks: checks)
  }

  private func usageCheck(_ usage: CanonicalUsage?) -> EndpointTestCheck {
    guard let usage, usage.inputTokens + usage.cacheReadTokens + usage.outputTokens > 0 else {
      return EndpointTestCheck(kind: .usage, outcome: .warning, detail: .noUsage)
    }
    return EndpointTestCheck(kind: .usage, outcome: .passed)
  }

  private struct Collected {
    var response: CanonicalResponse
    var usage: CanonicalUsage?
    var serverSteps: Int
    var firstEvent: ContinuousClock.Instant
    var end: ContinuousClock.Instant
  }

  /// One streamed turn, read to its end.
  private func collect(_ request: CanonicalRequest, route: GatewayRoute) async throws -> Collected {
    let side = EndpointSide(request, route: route)
    let response = try await transport.send(side.request, timeouts: route.endpoint.timeouts)
    guard (200..<300).contains(response.status) else {
      let body = (try? await response.collect(limit: 1_024 * 1_024)) ?? Data()
      throw EndpointFailure.http(
        status: response.status, body: body, retryAfter: response.headers["retry-after"])
    }
    var decoder = side.makeDecoder()
    var accumulator = CanonicalResponseAccumulator()
    var firstEvent: ContinuousClock.Instant?
    var steps = 0
    func take(_ events: [CanonicalStreamEvent]) {
      for event in events {
        if case .serverStep = event { steps += 1 }
        // The first sign of an answer, not of a stream opening.
        if firstEvent == nil {
          switch event {
          case .textDelta, .toolCallStart, .reasoningDelta, .serverStep: firstEvent = clock.now
          default: break
          }
        }
        accumulator.consume(event)
      }
    }
    try await EndpointSide.read(response, framing: side.framing, decoder: &decoder) { take($0) }
    let end = clock.now
    let answer = accumulator.response
    return Collected(
      response: answer, usage: answer.usage, serverSteps: steps, firstEvent: firstEvent ?? end,
      end: end)
  }

  static func detail(for failure: EndpointFailure) -> EndpointTestDetail {
    switch failure.kind {
    case .network: return .unreachable
    case .timeout: return .timedOut
    case .authentication where failure.status == nil: return .refusedKey
    default: return .endpointSaid(status: failure.status, message: failure.message)
    }
  }

  static func milliseconds(_ duration: Duration) -> Int {
    Int(
      duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
  }
}
