import Foundation

/// The session tokens the gateway accepts, and where each leads.
public actor GatewayRouteTable {
  private var routes: [String: GatewayRoute] = [:]

  public init() {}

  public func register(_ route: GatewayRoute, token: String) {
    routes[token] = route
  }

  public func remove(token: String) {
    routes[token] = nil
  }

  public func route(for token: String) -> GatewayRoute? {
    routes[token]
  }

  public var count: Int { routes.count }
}

/// When the gateway tries again, before anything reached the harness.
public struct GatewayRetryPolicy: Hashable, Sendable {
  public var maximumAttempts: Int
  public var baseDelay: Duration
  public var maximumDelay: Duration
  /// No attempt starts after this much time spent waiting.
  public var budget: Duration

  public init(
    maximumAttempts: Int = 5, baseDelay: Duration = .seconds(1),
    maximumDelay: Duration = .seconds(30), budget: Duration = .seconds(120)
  ) {
    self.maximumAttempts = maximumAttempts
    self.baseDelay = baseDelay
    self.maximumDelay = maximumDelay
    self.budget = budget
  }

  public static let standard = GatewayRetryPolicy()

  /// The wait before attempt `attempt + 1`, or `nil` to give up. `Retry-After` wins when the
  /// endpoint gives one within the budget; otherwise the wait doubles, with up to a quarter more at
  /// random so that sessions throttled together do not come back together.
  public func delay(
    after attempt: Int, failure: EndpointFailure, waited: Duration,
    jitter: Double = Double.random(in: 0...0.25)
  ) -> Duration? {
    guard failure.isRetryable, attempt < maximumAttempts else { return nil }
    var delay: Duration
    if let retryAfter = failure.retryAfter {
      delay = retryAfter
    } else {
      delay = baseDelay * Int(pow(2, Double(attempt - 1)))
      delay = min(delay, maximumDelay)
      delay += delay * jitter
    }
    guard waited + delay <= budget else { return nil }
    return delay
  }
}

/// Told what the gateway does that the session should show: a wait before another attempt, a step
/// an agent on the server ran. Never the content of a request.
public protocol GatewayObserving: Sendable {
  func retrying(
    token: String, attempt: Int, of maximum: Int, after delay: Duration,
    failure: EndpointFailure) async
  func serverStep(token: String, step: CanonicalServerStep) async
}

/// The gateway: a harness on one side, an endpoint on the other (#107).
///
/// Paths are `/s/<token>/v1/<operation>`. The token is a secret of the session, given to its harness
/// alone; it must also come back in the harness's own authentication header, so a URL seen in a
/// process list is not enough to use it.
///
/// Claude Code asks `messages`, Codex asks `responses`. When the endpoint speaks the same protocol,
/// the request goes through as it came, with the endpoint's model and credentials; otherwise it is
/// read into the canonical shape, written in the endpoint's protocol, and the answer comes back the
/// same way.
public final class Gateway: GatewayRequestHandling {
  private let routes: any GatewayRouting
  private let transport: any EndpointTransport
  private let retryPolicy: GatewayRetryPolicy
  private let sleep: @Sendable (Duration) async throws -> Void
  private let observer: (any GatewayObserving)?

  public init(
    routes: any GatewayRouting,
    transport: any EndpointTransport,
    retryPolicy: GatewayRetryPolicy = .standard,
    observer: (any GatewayObserving)? = nil,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.routes = routes
    self.transport = transport
    self.retryPolicy = retryPolicy
    self.observer = observer
    self.sleep = sleep
  }

  public func handle(_ request: GatewayHTTPRequest, writer: any GatewayResponseWriter) async {
    // Claude Code checks that its base URL answers before its first request.
    if request.method == "HEAD" {
      await writer.start(status: 200, headers: ["content-length": "0"])
      return
    }
    let parts = request.path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 4, parts[0] == "s", parts[2] == "v1" else {
      await writer.respond(status: 404, json: Self.error("not_found_error", "Unknown path."))
      return
    }
    let token = String(parts[1])
    let operation = parts[3...].joined(separator: "/")
    let harness: HarnessProtocol = operation.hasPrefix("responses") ? .responses : .messages
    guard Self.presented(token, in: request.headers), let route = await routes.route(for: token)
    else {
      let failure = EndpointFailure(
        kind: .authentication,
        message: "This session is not known to the gateway. Restart it from Vibe Manager.")
      await Self.respond(failure, harness: harness, writer: writer)
      return
    }
    switch (request.method, operation) {
    case ("POST", "messages"), ("POST", "responses"):
      await converse(request, harness: harness, route: route, token: token, writer: writer)
    case ("POST", "messages/count_tokens"):
      await countTokens(request, writer: writer)
    case ("GET", "models"):
      await writer.respond(
        status: 200,
        json: [
          "object": "list",
          "data": [["id": .string(route.model), "object": "model", "type": "model"]],
          "has_more": false,
        ])
    default:
      await writer.respond(
        status: 404, json: Self.error("not_found_error", "Unknown operation \(operation)."))
    }
  }

  /// The token must also come as the harness's credential: `Authorization: Bearer` for both CLIs,
  /// `x-api-key` for Claude Code when it is given an API key rather than a token.
  static func presented(_ token: String, in headers: [String: String]) -> Bool {
    if let authorization = headers["authorization"], authorization == "Bearer \(token)" {
      return true
    }
    return headers["x-api-key"] == token
  }

  private static func error(_ type: String, _ message: String) -> JSONValue {
    ["type": "error", "error": ["type": .string(type), "message": .string(message)]]
  }

  /// A failure before any byte of an answer, in the harness's protocol.
  static func respond(
    _ failure: EndpointFailure, harness: HarnessProtocol, writer: any GatewayResponseWriter
  ) async {
    switch harness {
    case .messages:
      await writer.respond(
        status: AnthropicMessagesServer.status(for: failure),
        json: AnthropicMessagesServer.errorBody(failure))
    case .responses:
      await writer.respond(
        status: ResponsesServer.status(for: failure), json: ResponsesServer.errorBody(failure))
    }
  }

  private func countTokens(_ request: GatewayHTTPRequest, writer: any GatewayResponseWriter) async {
    guard let body = try? JSONValue(parsing: request.body),
      let canonical = try? AnthropicMessagesServer.decodeRequest(body)
    else {
      await Self.respond(
        EndpointFailure(kind: .invalidRequest, message: "The request is not a Messages request."),
        harness: .messages, writer: writer)
      return
    }
    await writer.respond(
      status: 200,
      json: [
        "input_tokens": .number(Double(AnthropicMessagesServer.estimatedInputTokens(canonical)))
      ])
  }

  // MARK: - A turn

  private func converse(
    _ request: GatewayHTTPRequest, harness: HarnessProtocol, route: GatewayRoute, token: String,
    writer: any GatewayResponseWriter
  ) async {
    guard let body = try? JSONValue(parsing: request.body), case .object(var fields) = body else {
      await Self.respond(
        EndpointFailure(kind: .invalidRequest, message: "The request is not JSON."),
        harness: harness, writer: writer)
      return
    }
    switch (harness, route.endpoint.wireProtocol) {
    case (.messages, .messages), (.responses, .responses):
      fields["model"] = .string(route.model)
      await passThrough(
        .object(fields), harness: harness, harnessHeaders: request.headers, route: route,
        token: token, writer: writer)
      return
    default:
      break
    }
    let side: HarnessSide
    do {
      side = try HarnessSide(harness, body: .object(fields), model: route.model)
    } catch {
      await Self.respond(
        EndpointFailure(
          kind: .invalidRequest, message: "The request does not follow the harness's protocol."),
        harness: harness, writer: writer)
      return
    }
    await translate(side, route: route, token: token, writer: writer)
  }

  /// The same protocol on both sides: the body goes out with the endpoint's model and credentials,
  /// and the answer comes back byte for byte.
  private func passThrough(
    _ body: JSONValue, harness: HarnessProtocol, harnessHeaders: [String: String],
    route: GatewayRoute, token: String, writer: any GatewayResponseWriter
  ) async {
    var headers = route.endpoint.requestHeaders(secret: route.secret)
    headers["content-type"] = "application/json"
    let operation: String
    switch harness {
    case .messages:
      for name in ["anthropic-version", "anthropic-beta", "accept"] {
        if let value = harnessHeaders[name] { headers[name] = value }
      }
      if headers["anthropic-version"] == nil { headers["anthropic-version"] = "2023-06-01" }
      operation = route.endpoint.messagesOperation
    case .responses:
      for name in ["openai-beta", "accept"] {
        if let value = harnessHeaders[name] { headers[name] = value }
      }
      operation = ResponsesClient.path
    }
    let request = EndpointHTTPRequest(
      url: route.endpoint.url(for: operation, secret: route.secret), headers: headers,
      body: body.data())
    await attempt(request, token: token, route: route, harness: harness, writer: writer) {
      response, commit in
      await commit(
        response.status,
        ["content-type": response.headers["content-type"] ?? "application/json"])
      do {
        for try await chunk in response.body { await writer.write(chunk) }
      } catch {
        // Cut after part of the answer went through. Claude Code retries on an error event; Codex
        // retries a stream that ends without its completion, which closing now gives it.
        guard harness == .messages else { return }
        let failure = error as? EndpointFailure ?? UnexpectedFailure.wrap(error)
        await writer.write(
          ServerSentEvent(name: "error", data: AnthropicMessagesServer.errorBody(failure).text())
            .encoded)
      }
    }
  }

  private func translate(
    _ side: HarnessSide, route: GatewayRoute, token: String, writer: any GatewayResponseWriter
  ) async {
    let endpoint = EndpointSide(side.request, route: route)
    let observer = self.observer
    await attempt(
      endpoint.request, token: token, route: route, harness: side.harness, writer: writer
    ) { response, commit in
      guard side.request.stream else {
        let data = try await response.collect()
        guard let json = try? JSONValue(parsing: data) else {
          throw EndpointFailure(kind: .malformedResponse, message: "The answer is not JSON.")
        }
        var answer = try endpoint.decodeWhole(json)
        if answer.id.isEmpty { answer.id = side.fallbackID }
        answer.model = route.model
        for step in answer.serverSteps { await observer?.serverStep(token: token, step: step) }
        let encoded = side.whole(answer).data()
        await commit(200, ["content-type": "application/json"])
        await writer.write(encoded)
        return
      }
      var decoder = endpoint.makeDecoder()
      var encoder = side.makeEncoder()
      var committed = false
      func forward(_ events: [CanonicalStreamEvent]) async {
        for event in events {
          var event = event
          // The harness is told the model it asked for, under an identifier it can keep.
          if case .start(let id, _) = event {
            event = .start(id: id.isEmpty ? side.fallbackID : id, model: route.model)
          }
          if case .serverStep(let step) = event {
            await observer?.serverStep(token: token, step: step)
          }
          let out = encoder.encode(event)
          guard !out.isEmpty else { continue }
          if !committed {
            committed = true
            await commit(200, Self.streamHeaders)
          }
          for sse in out { await writer.write(sse.encoded) }
        }
      }
      do {
        try await EndpointSide.read(
          response, framing: endpoint.framing, decoder: &decoder, forward: forward)
      } catch {
        // Once the harness has seen part of the answer, only its own stream can take it back: the
        // harness drops the partial answer and asks again.
        guard committed else { throw error }
        let failure = (error as? EndpointFailure ?? UnexpectedFailure.wrap(error))
          .redacting(route.secret)
        for sse in encoder.fail(failure) { await writer.write(sse.encoded) }
        return
      }
      if !committed { await commit(200, Self.streamHeaders) }
      for sse in encoder.finish() { await writer.write(sse.encoded) }
    }
  }

  static let streamHeaders = [
    "content-type": "text/event-stream", "cache-control": "no-cache",
  ]

  // MARK: - Attempts

  /// Sends `request`, and runs `answer` on a successful response. Until `answer` commits a status to
  /// the harness, a retryable failure is tried again after the policy's wait; after, the failure is
  /// `answer`'s to report in its own stream, and nothing else is written.
  private func attempt(
    _ request: EndpointHTTPRequest, token: String, route: GatewayRoute, harness: HarnessProtocol,
    writer: any GatewayResponseWriter,
    answer: (
      EndpointHTTPResponse, _ commit: @escaping @Sendable (Int, [String: String]) async -> Void
    ) async throws -> Void
  ) async {
    let committed = CommitFlag()
    let commit: @Sendable (Int, [String: String]) async -> Void = { status, headers in
      committed.set()
      await writer.start(status: status, headers: headers)
    }
    var waited: Duration = .zero
    var number = 0
    while true {
      number += 1
      let failure: EndpointFailure
      do {
        let response = try await transport.send(request, timeouts: route.endpoint.timeouts)
        guard (200..<300).contains(response.status) else {
          let body = (try? await response.collect(limit: 1_024 * 1_024)) ?? Data()
          throw EndpointFailure.http(
            status: response.status, body: body, retryAfter: response.headers["retry-after"])
        }
        try await answer(response, commit)
        return
      } catch let error as EndpointFailure {
        failure = error.redacting(route.secret)
      } catch is CancellationError {
        return
      } catch {
        failure = UnexpectedFailure.wrap(error)
      }
      if committed.isSet { return }
      guard let delay = retryPolicy.delay(after: number, failure: failure, waited: waited) else {
        await Self.respond(failure, harness: harness, writer: writer)
        return
      }
      await observer?.retrying(
        token: token, attempt: number + 1, of: retryPolicy.maximumAttempts, after: delay,
        failure: failure)
      do {
        try await sleep(delay)
      } catch {
        await Self.respond(failure, harness: harness, writer: writer)
        return
      }
      waited += delay
    }
  }
}

private final class CommitFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

// MARK: - The two sides

protocol HarnessStreamEncoding: Sendable {
  mutating func encode(_ event: CanonicalStreamEvent) -> [ServerSentEvent]
  mutating func finish() -> [ServerSentEvent]
  mutating func fail(_ failure: EndpointFailure) -> [ServerSentEvent]
}

extension AnthropicMessagesStreamEncoder: HarnessStreamEncoding {}
extension ResponsesStreamEncoder: HarnessStreamEncoding {}

protocol EndpointStreamDecoding: Sendable {
  mutating func consume(_ event: ServerSentEvent) throws -> [CanonicalStreamEvent]
  mutating func consumeStray(_ line: String) -> [CanonicalStreamEvent]
  mutating func finish() throws -> [CanonicalStreamEvent]
}

extension EndpointStreamDecoding {
  /// One JSON object that is not in an SSE frame: a line of NDJSON, or a whole answer.
  mutating func consumeObject(_ text: String) throws -> [CanonicalStreamEvent] {
    try consume(ServerSentEvent(data: text))
  }
}

extension CustomProtocolDecoder: EndpointStreamDecoding {}

/// How an endpoint's answer is cut into the objects its decoder reads.
enum EndpointFraming: Sendable {
  case sse
  /// One JSON object per line.
  case ndjson
  /// One JSON object, the whole answer.
  case whole
}

extension EndpointSide {
  /// Reads a streamed answer to its end, handing each group of events to `forward` as it comes.
  static func read(
    _ response: EndpointHTTPResponse, framing: EndpointFraming,
    decoder: inout any EndpointStreamDecoding,
    forward: ([CanonicalStreamEvent]) async -> Void
  ) async throws {
    switch framing {
    case .sse:
      var parser = ServerSentEventParser()
      for try await chunk in response.body {
        for event in parser.consume(chunk) { await forward(try decoder.consume(event)) }
      }
      if let last = parser.finish() { await forward(try decoder.consume(last)) }
      for line in parser.strayLines { await forward(decoder.consumeStray(line)) }
    case .ndjson:
      var buffer = Data()
      for try await chunk in response.body {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
          let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
          buffer.removeSubrange(buffer.startIndex...newline)
          if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            await forward(try decoder.consumeObject(line))
          }
        }
      }
      let rest = String(decoding: buffer, as: UTF8.self)
      if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        await forward(try decoder.consumeObject(rest))
      }
    case .whole:
      let data = try await response.collect()
      await forward(try decoder.consumeObject(String(decoding: data, as: UTF8.self)))
    }
    await forward(try decoder.finish())
  }
}

extension ChatCompletionsStreamDecoder: EndpointStreamDecoding {}

extension ResponsesStreamDecoder: EndpointStreamDecoding {
  mutating func consumeStray(_ line: String) -> [CanonicalStreamEvent] { [] }
}

extension AnthropicMessagesStreamDecoder: EndpointStreamDecoding {
  mutating func consumeStray(_ line: String) -> [CanonicalStreamEvent] { [] }
}

/// What the harness asked, and how to answer it.
struct HarnessSide: Sendable {
  let harness: HarnessProtocol
  let request: CanonicalRequest
  let fallbackID: String
  let makeEncoder: @Sendable () -> any HarnessStreamEncoding
  let whole: @Sendable (CanonicalResponse) -> JSONValue

  init(_ harness: HarnessProtocol, body: JSONValue, model: String) throws {
    self.harness = harness
    let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    switch harness {
    case .messages:
      var request = try AnthropicMessagesServer.decodeRequest(body)
      request.model = model
      self.request = request
      let id = "msg_" + identifier
      fallbackID = id
      makeEncoder = { AnthropicMessagesStreamEncoder(id: id, model: model) }
      whole = { AnthropicMessagesServer.encodeResponse($0) }
    case .responses:
      let decoded = try ResponsesServer.decodeRequest(body)
      var request = decoded.request
      request.model = model
      self.request = request
      let id = "resp_" + identifier
      fallbackID = id
      let custom = decoded.customTools
      makeEncoder = { ResponsesStreamEncoder(id: id, model: model, customTools: custom) }
      whole = { answer in
        var encoder = ResponsesStreamEncoder(id: id, model: model, customTools: custom)
        return encoder.response(answer)
      }
    }
  }
}

/// The request in the endpoint's protocol, and how to read its answer.
struct EndpointSide: Sendable {
  let request: EndpointHTTPRequest
  let framing: EndpointFraming
  let makeDecoder: @Sendable () -> any EndpointStreamDecoding
  let decodeWhole: @Sendable (JSONValue) throws -> CanonicalResponse

  init(_ canonical: CanonicalRequest, route: GatewayRoute) {
    let endpoint = route.endpoint
    var body: [String: JSONValue]
    let operation: String
    var framing = EndpointFraming.sse
    switch endpoint.wireProtocol {
    case .custom:
      // `init?(_ endpoint:)` refuses a custom endpoint without a document that reads.
      let document =
        endpoint.customProtocol
        ?? CustomProtocolDocument(
          request: .init(method: "POST", path: "", body: [:]), stream: .none, rules: [],
          models: nil)
      body = document.body(for: canonical).objectValue ?? [:]
      operation = document.operationPath(model: canonical.model)
      switch document.stream {
      case .sse: framing = .sse
      case .ndjson: framing = .ndjson
      case .none: framing = .whole
      }
      makeDecoder = { CustomProtocolDecoder(document: document) }
      decodeWhole = { json in
        var decoder = CustomProtocolDecoder(document: document)
        var accumulator = CanonicalResponseAccumulator()
        for event in try decoder.consume(json) + decoder.finish() { accumulator.consume(event) }
        return accumulator.response
      }
    case .chatCompletions:
      body = ChatCompletionsClient.encodeRequest(canonical).objectValue ?? [:]
      operation = ChatCompletionsClient.path
      makeDecoder = { ChatCompletionsStreamDecoder() }
      decodeWhole = { try ChatCompletionsClient.decodeResponse($0) }
    case .responses:
      body = ResponsesClient.encodeRequest(canonical).objectValue ?? [:]
      operation = ResponsesClient.path
      makeDecoder = { ResponsesStreamDecoder() }
      decodeWhole = { try ResponsesClient.decodeResponse($0) }
    case .messages:
      body =
        AnthropicMessagesClient.encodeRequest(
          canonical, defaultMaximumTokens: endpoint.defaultParameters["max_tokens"]?.intValue
        ).objectValue ?? [:]
      operation = endpoint.messagesOperation
      makeDecoder = { AnthropicMessagesStreamDecoder() }
      decodeWhole = { try AnthropicMessagesClient.decodeResponse($0) }
    }
    for (key, value) in endpoint.defaultParameters {
      // `null` takes a field out: for an endpoint that refuses one the gateway sends.
      if value.isNull {
        body[key] = nil
      } else if body[key] == nil {
        body[key] = value
      }
    }
    var headers = endpoint.requestHeaders(secret: route.secret)
    headers["content-type"] = "application/json"
    headers["accept"] = canonical.stream ? "text/event-stream" : "application/json"
    if endpoint.wireProtocol == .messages, headers["anthropic-version"] == nil {
      headers["anthropic-version"] = "2023-06-01"
    }
    self.framing = framing
    let method = endpoint.customProtocol?.request.method ?? "POST"
    request = EndpointHTTPRequest(
      url: endpoint.url(for: operation, secret: route.secret), method: method, headers: headers,
      body: method == "GET" ? nil : JSONValue.object(body).data())
  }
}

/// A failure the gateway did not classify, from code that should only throw `EndpointFailure`.
enum UnexpectedFailure {
  static func wrap(_ error: any Error) -> EndpointFailure {
    EndpointFailure(kind: .server, message: "The gateway failed to read the answer.")
  }
}
