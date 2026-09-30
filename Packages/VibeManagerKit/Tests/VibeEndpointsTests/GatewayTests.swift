import Foundation
import Testing

@testable import VibeEndpoints

/// An endpoint that answers from a script, one entry per request, and records what it was sent.
final class ScriptedTransport: EndpointTransport, @unchecked Sendable {
  enum Step {
    case answer(
      status: Int, headers: [String: String], chunks: [String], thenFail: EndpointFailure?)
    case fail(EndpointFailure)
  }

  private let lock = NSLock()
  private var steps: [Step]
  private(set) var requests: [EndpointHTTPRequest] = []

  init(_ steps: [Step]) {
    self.steps = steps
  }

  var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return requests.count
  }

  func sentBody(_ index: Int) throws -> JSONValue {
    lock.lock()
    defer { lock.unlock() }
    return try JSONValue(parsing: requests[index].body ?? Data())
  }

  func send(_ request: EndpointHTTPRequest, timeouts: EndpointTimeouts) async throws
    -> EndpointHTTPResponse
  {
    let step: Step = {
      lock.lock()
      defer { lock.unlock() }
      requests.append(request)
      return steps.isEmpty
        ? .fail(EndpointFailure(kind: .server, message: "script ended")) : steps.removeFirst()
    }()
    switch step {
    case .fail(let failure):
      throw failure
    case .answer(let status, let headers, let chunks, let thenFail):
      let body = AsyncThrowingStream<Data, any Error> { continuation in
        for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
        if let thenFail { continuation.finish(throwing: thenFail) } else { continuation.finish() }
      }
      return EndpointHTTPResponse(status: status, headers: headers, body: body)
    }
  }
}

/// Collects what the gateway writes to the harness.
actor RecordingWriter: GatewayResponseWriter {
  private(set) var status: Int?
  private(set) var headers: [String: String] = [:]
  private(set) var body = Data()
  private(set) var finished = false

  func start(status: Int, headers: [String: String]) {
    guard self.status == nil else { return }
    self.status = status
    self.headers = headers
  }

  func write(_ data: Data) { body.append(data) }
  func finish() { finished = true }

  var events: [ServerSentEvent] {
    var parser = ServerSentEventParser()
    return parser.consume(body) + [parser.finish()].compactMap { $0 }
  }

  var json: JSONValue? { try? JSONValue(parsing: body) }
}

actor RecordingObserver: GatewayObserving {
  private(set) var retries: [(attempt: Int, delay: Duration, kind: EndpointFailure.Kind)] = []
  private(set) var steps: [CanonicalServerStep] = []

  func retrying(
    token: String, attempt: Int, of maximum: Int, after delay: Duration, failure: EndpointFailure
  ) {
    retries.append((attempt, delay, failure.kind))
  }

  func serverStep(token: String, step: CanonicalServerStep) {
    steps.append(step)
  }
}

@Suite("The gateway between Claude Code and an endpoint")
struct GatewayTests {
  static let token = "t0k3n"
  static let chunks = [
    #"data: {"id":"gen-9","model":"up","choices":[{"delta":{"content":"Hello"}}]}"# + "\n\n",
    #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":1}}"#
      + "\n\n",
    "data: [DONE]\n\n",
  ]

  private func gateway(
    _ transport: ScriptedTransport, protocol wire: EndpointWireProtocol = .chatCompletions,
    observer: RecordingObserver? = nil, parameters: [String: JSONValue] = [:]
  ) async throws -> Gateway {
    let routes = GatewayRouteTable()
    await routes.register(
      GatewayRoute(
        endpoint: EndpointConfiguration(
          baseURL: try #require(URL(string: "https://llm.example/api/v1")), wireProtocol: wire,
          defaultParameters: parameters),
        secret: "sk-secret", model: "qwen/qwen3-coder"),
      token: Self.token)
    return Gateway(
      routes: routes, transport: transport, retryPolicy: GatewayRetryPolicy(budget: .seconds(600)),
      observer: observer, sleep: { _ in })
  }

  private func request(
    _ operation: String = "messages", stream: Bool = true, token: String = token,
    method: String = "POST"
  ) -> GatewayHTTPRequest {
    GatewayHTTPRequest(
      method: method, path: "/s/\(Self.token)/v1/\(operation)",
      headers: ["authorization": "Bearer \(token)", "anthropic-version": "2023-06-01"],
      body: Data(
        #"{"model":"claude-sonnet-5-5","max_tokens":100,"stream":\#(stream),"messages":[{"role":"user","content":"Hi"}]}"#
          .utf8))
  }

  @Test("A streamed answer is translated, the endpoint's model and secret are used")
  func translatesStream() async throws {
    let transport = ScriptedTransport([
      .answer(status: 200, headers: [:], chunks: Self.chunks, thenFail: nil)
    ])
    let writer = RecordingWriter()
    try await gateway(
      transport, parameters: ["provider": ["sort": "throughput"], "stream_options": nil])
      .handle(request(), writer: writer)

    #expect(await writer.status == 200)
    #expect(await writer.headers["content-type"] == "text/event-stream")
    let events = await writer.events
    #expect(
      events.map(\.name) == [
        "message_start", "content_block_start", "content_block_delta", "content_block_stop",
        "message_delta", "message_stop",
      ])
    #expect(events[0].data.contains(#""model":"qwen/qwen3-coder""#))
    #expect(events[4].data.contains(#""input_tokens":12"#))
    let sent = transport.requests[0]
    #expect(sent.url.absoluteString == "https://llm.example/api/v1/chat/completions")
    #expect(sent.headers["Authorization"] == "Bearer sk-secret")
    let body = try transport.sentBody(0)
    #expect(body["model"] == "qwen/qwen3-coder")
    #expect(body["provider"] == ["sort": "throughput"])
    #expect(body["stream_options"] == nil)
  }

  @Test("A request that does not stream gets a whole Messages answer")
  func translatesWhole() async throws {
    let transport = ScriptedTransport([
      .answer(
        status: 200, headers: [:],
        chunks: [
          #"{"id":"a","model":"up","choices":[{"message":{"content":"Done"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1}}"#
        ], thenFail: nil)
    ])
    let writer = RecordingWriter()
    try await gateway(transport).handle(request(stream: false), writer: writer)
    let json = try #require(await writer.json)
    #expect(json["content"] == [["type": "text", "text": "Done"]])
    #expect(json["model"] == "qwen/qwen3-coder")
    #expect(json["stop_reason"] == "end_turn")
  }

  @Test("429 then 503 then an answer: two waits, Retry-After honoured, the turn goes through")
  func retriesBeforeTheFirstByte() async throws {
    let transport = ScriptedTransport([
      .answer(
        status: 429, headers: ["retry-after": "7"], chunks: [#"{"error":{"message":"slow"}}"#],
        thenFail: nil),
      .answer(status: 503, headers: [:], chunks: [], thenFail: nil),
      .answer(status: 200, headers: [:], chunks: Self.chunks, thenFail: nil),
    ])
    let observer = RecordingObserver()
    let writer = RecordingWriter()
    try await gateway(transport, observer: observer).handle(request(), writer: writer)

    #expect(transport.requestCount == 3)
    let retries = await observer.retries
    #expect(retries.map(\.attempt) == [2, 3])
    #expect(retries.first?.delay == .seconds(7))
    #expect(retries.map(\.kind) == [.rateLimited, .overloaded])
    #expect(await writer.status == 200)
    #expect(await writer.events.last?.name == "message_stop")
  }

  @Test("An error chunk before any text is retried too: nothing had reached Claude Code")
  func retriesAnEarlyErrorChunk() async throws {
    let transport = ScriptedTransport([
      .answer(
        status: 200, headers: [:],
        chunks: [#"data: {"error":{"message":"Upstream overloaded","code":503}}"# + "\n\n"],
        thenFail: nil),
      .answer(status: 200, headers: [:], chunks: Self.chunks, thenFail: nil),
    ])
    let writer = RecordingWriter()
    try await gateway(transport).handle(request(), writer: writer)
    #expect(transport.requestCount == 2)
    #expect(await writer.events.last?.name == "message_stop")
  }

  @Test("Cut after the first words: an error event Claude Code retries, and no second request")
  func cutMidStream() async throws {
    let transport = ScriptedTransport([
      .answer(
        status: 200, headers: [:], chunks: [Self.chunks[0]],
        thenFail: EndpointFailure(
          kind: .network, message: "The connection to the endpoint was lost."))
    ])
    let writer = RecordingWriter()
    try await gateway(transport).handle(request(), writer: writer)
    #expect(transport.requestCount == 1)
    let events = await writer.events
    #expect(events.last?.name == "error")
    #expect(events.last?.data.contains("overloaded_error") == true)
  }

  @Test("A refused key is not retried, and says what to do")
  func authenticationIsFinal() async throws {
    let transport = ScriptedTransport([
      .answer(
        status: 401, headers: [:], chunks: [#"{"error":{"message":"Invalid API key"}}"#],
        thenFail: nil)
    ])
    let writer = RecordingWriter()
    try await gateway(transport).handle(request(), writer: writer)
    #expect(transport.requestCount == 1)
    #expect(await writer.status == 401)
    #expect(await writer.json?["error"]?["type"] == "authentication_error")
    #expect(await writer.json?["error"]?["message"] == "HTTP 401: Invalid API key")
  }

  @Test("A key the endpoint quotes back never reaches the session")
  func canary() async throws {
    let canary = "sk-VIBE-CANARY-\(UUID().uuidString)"
    let transport = ScriptedTransport([
      .answer(
        status: 401, headers: [:],
        chunks: [#"{"error":{"message":"Invalid API key: "# + canary + #""}}"#], thenFail: nil)
    ])
    let routes = GatewayRouteTable()
    await routes.register(
      GatewayRoute(
        endpoint: EndpointConfiguration(
          baseURL: try #require(URL(string: "https://llm.example/v1")), wireProtocol: .chatCompletions),
        secret: canary, model: "m"),
      token: Self.token)
    let writer = RecordingWriter()
    await Gateway(routes: routes, transport: transport, sleep: { _ in }).handle(
      request(), writer: writer)
    let body = String(decoding: await writer.body, as: UTF8.self)
    #expect(body.contains("Invalid API key"))
    #expect(!body.contains("VIBE-CANARY"))
    // The key went to the endpoint, and nowhere else the harness can see.
    #expect(transport.requests[0].headers["Authorization"] == "Bearer \(canary)")
  }

  @Test("Giving up after the last attempt answers with the last failure")
  func givesUp() async throws {
    let busy = EndpointFailure(kind: .overloaded, message: "busy")
    let transport = ScriptedTransport(Array(repeating: .fail(busy), count: 5))
    let writer = RecordingWriter()
    try await gateway(transport).handle(request(), writer: writer)
    #expect(transport.requestCount == 5)
    #expect(await writer.status == 529)
  }

  @Test("The token must be in the path and in the credential; an unknown one is refused")
  func tokens() async throws {
    let transport = ScriptedTransport([])
    let gateway = try await gateway(transport)
    for bad in [
      request(token: "other"), GatewayHTTPRequest(method: "POST", path: "/s/other/v1/messages"),
    ] {
      let writer = RecordingWriter()
      await gateway.handle(bad, writer: writer)
      #expect(await writer.status == 401)
    }
    let writer = RecordingWriter()
    await gateway.handle(GatewayHTTPRequest(method: "GET", path: "/v1/models"), writer: writer)
    #expect(await writer.status == 404)
    #expect(transport.requestCount == 0)
  }

  @Test("The HEAD Claude Code sends to check its base URL is answered")
  func head() async throws {
    let writer = RecordingWriter()
    try await gateway(ScriptedTransport([])).handle(
      GatewayHTTPRequest(method: "HEAD", path: "/s/\(Self.token)/api/hello"), writer: writer)
    #expect(await writer.status == 200)
  }

  @Test("count_tokens and models are answered by the gateway itself")
  func localOperations() async throws {
    let transport = ScriptedTransport([])
    let gateway = try await gateway(transport)
    let count = RecordingWriter()
    await gateway.handle(request("messages/count_tokens"), writer: count)
    #expect((await count.json?["input_tokens"]?.intValue ?? 0) > 0)
    let models = RecordingWriter()
    await gateway.handle(request("models", method: "GET"), writer: models)
    #expect(await models.json?["data"]?.arrayValue?.first?["id"] == "qwen/qwen3-coder")
    #expect(transport.requestCount == 0)
  }

  @Test("A Messages endpoint gets the body as sent, with its own model, and answers byte for byte")
  func passThrough() async throws {
    let upstream = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"
    let transport = ScriptedTransport([
      .answer(
        status: 200, headers: ["content-type": "text/event-stream"], chunks: [upstream],
        thenFail: nil)
    ])
    let writer = RecordingWriter()
    try await gateway(transport, protocol: .messages).handle(request(), writer: writer)
    #expect(String(decoding: await writer.body, as: UTF8.self) == upstream)
    let sent = transport.requests[0]
    #expect(sent.url.absoluteString == "https://llm.example/api/v1/messages")
    #expect(sent.headers["anthropic-version"] == "2023-06-01")
    #expect(try transport.sentBody(0)["model"] == "qwen/qwen3-coder")
    #expect(try transport.sentBody(0)["max_tokens"] == 100)
  }
}
