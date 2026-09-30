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
public final class Gateway: GatewayRequestHandling {
  private let routes: GatewayRouteTable
  private let transport: any EndpointTransport
  private let retryPolicy: GatewayRetryPolicy
  private let sleep: @Sendable (Duration) async throws -> Void
  private let observer: (any GatewayObserving)?

  public init(
    routes: GatewayRouteTable,
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
      await writer.respond(status: 404, json: notFound("Unknown path."))
      return
    }
    let token = String(parts[1])
    let operation = parts[3...].joined(separator: "/")
    guard Self.presented(token, in: request.headers), let route = await routes.route(for: token)
    else {
      await writer.respond(
        status: 401,
        json: AnthropicMessagesServer.errorBody(
          EndpointFailure(
            kind: .authentication,
            message: "This session is not known to the gateway. Restart it from Vibe Manager.")))
      return
    }
    switch (request.method, operation) {
    case ("POST", "messages"):
      await messages(request, route: route, token: token, writer: writer)
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
      await writer.respond(status: 404, json: notFound("Unknown operation \(operation)."))
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

  private func notFound(_ message: String) -> JSONValue {
    ["type": "error", "error": ["type": "not_found_error", "message": .string(message)]]
  }

  private func invalid(_ message: String) -> JSONValue {
    AnthropicMessagesServer.errorBody(EndpointFailure(kind: .invalidRequest, message: message))
  }

  // MARK: - Claude Code

  private func countTokens(_ request: GatewayHTTPRequest, writer: any GatewayResponseWriter) async {
    guard let body = try? JSONValue(parsing: request.body),
      let canonical = try? AnthropicMessagesServer.decodeRequest(body)
    else {
      await writer.respond(status: 400, json: invalid("The request is not a Messages request."))
      return
    }
    await writer.respond(
      status: 200,
      json: [
        "input_tokens": .number(Double(AnthropicMessagesServer.estimatedInputTokens(canonical)))
      ]
    )
  }

  private func messages(
    _ request: GatewayHTTPRequest, route: GatewayRoute, token: String,
    writer: any GatewayResponseWriter
  ) async {
    guard let body = try? JSONValue(parsing: request.body), case .object(var fields) = body else {
      await writer.respond(status: 400, json: invalid("The request is not JSON."))
      return
    }
    switch route.endpoint.wireProtocol {
    case .messages:
      fields["model"] = .string(route.model)
      await passThroughMessages(
        .object(fields), harnessHeaders: request.headers, route: route, token: token,
        writer: writer)
    case .chatCompletions:
      let canonical: CanonicalRequest
      do {
        canonical = try AnthropicMessagesServer.decodeRequest(.object(fields))
      } catch {
        await writer.respond(status: 400, json: invalid("The request is not a Messages request."))
        return
      }
      var translated = canonical
      translated.model = route.model
      await translateMessagesToChat(translated, route: route, token: token, writer: writer)
    case .responses:
      await writer.respond(
        status: 501,
        json: AnthropicMessagesServer.errorBody(
          EndpointFailure(
            kind: .invalidRequest,
            message: "Claude Code cannot drive a Responses endpoint yet; choose Codex.")))
    }
  }

  /// A Messages endpoint behind Claude Code: nothing to translate. The body goes out with the
  /// endpoint's model and credentials, and the answer comes back byte for byte.
  private func passThroughMessages(
    _ body: JSONValue, harnessHeaders: [String: String], route: GatewayRoute, token: String,
    writer: any GatewayResponseWriter
  ) async {
    var headers = route.endpoint.requestHeaders(secret: route.secret)
    headers["content-type"] = "application/json"
    for name in ["anthropic-version", "anthropic-beta", "accept"] {
      if let value = harnessHeaders[name] { headers[name] = value }
    }
    if headers["anthropic-version"] == nil { headers["anthropic-version"] = "2023-06-01" }
    let request = EndpointHTTPRequest(
      url: route.endpoint.url(for: route.endpoint.messagesOperation, secret: route.secret),
      headers: headers,
      body: body.data())
    await attempt(
      request, token: token, route: route, writer: writer, failed: messagesFailure
    ) { response, commit in
      await commit(
        response.status,
        ["content-type": response.headers["content-type"] ?? "application/json"])
      do {
        for try await chunk in response.body { await writer.write(chunk) }
      } catch {
        // Cut after part of the answer went through: an error event in the stream, which Claude
        // Code retries, rather than an answer that just stops.
        let failure = error as? EndpointFailure ?? UnexpectedFailure.wrap(error)
        await writer.write(
          ServerSentEvent(name: "error", data: AnthropicMessagesServer.errorBody(failure).text())
            .encoded)
      }
    }
  }

  private func translateMessagesToChat(
    _ canonical: CanonicalRequest, route: GatewayRoute, token: String,
    writer: any GatewayResponseWriter
  ) async {
    var body = ChatCompletionsClient.encodeRequest(canonical).objectValue ?? [:]
    for (key, value) in route.endpoint.defaultParameters where body[key] == nil {
      body[key] = value
    }
    var headers = route.endpoint.requestHeaders(secret: route.secret)
    headers["content-type"] = "application/json"
    headers["accept"] = canonical.stream ? "text/event-stream" : "application/json"
    let request = EndpointHTTPRequest(
      url: route.endpoint.url(for: ChatCompletionsClient.path, secret: route.secret),
      headers: headers, body: JSONValue.object(body).data())
    let fallbackID = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let observer = self.observer
    await attempt(
      request, token: token, route: route, writer: writer, failed: messagesFailure
    ) { response, commit in
      guard canonical.stream else {
        let data = try await response.collect()
        guard let json = try? JSONValue(parsing: data) else {
          throw EndpointFailure(kind: .malformedResponse, message: "The answer is not JSON.")
        }
        var answer = try ChatCompletionsClient.decodeResponse(json)
        if answer.id.isEmpty { answer.id = fallbackID }
        answer.model = route.model
        for step in answer.serverSteps { await observer?.serverStep(token: token, step: step) }
        let encoded = AnthropicMessagesServer.encodeResponse(answer).data()
        await commit(200, ["content-type": "application/json"])
        await writer.write(encoded)
        return
      }
      var parser = ServerSentEventParser()
      var decoder = ChatCompletionsStreamDecoder()
      var encoder = AnthropicMessagesStreamEncoder(id: fallbackID, model: route.model)
      var committed = false
      func forward(_ events: [CanonicalStreamEvent]) async {
        for event in events {
          var event = event
          if case .start(let id, _) = event {
            event = .start(id: id.isEmpty ? fallbackID : id, model: route.model)
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
        for try await chunk in response.body {
          for event in parser.consume(chunk) { await forward(try decoder.consume(event)) }
        }
        if let last = parser.finish() { await forward(try decoder.consume(last)) }
        for line in parser.strayLines { await forward(decoder.consumeStray(line)) }
        await forward(try decoder.finish())
      } catch {
        // Once the harness has seen part of the answer, only an error in its own stream can take
        // it back: Claude Code drops the partial answer and asks again.
        guard committed else { throw error }
        let failure = error as? EndpointFailure ?? UnexpectedFailure.wrap(error)
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

  private func messagesFailure(_ failure: EndpointFailure, writer: any GatewayResponseWriter) async
  {
    await writer.respond(
      status: AnthropicMessagesServer.status(for: failure),
      json: AnthropicMessagesServer.errorBody(failure))
  }

  // MARK: - Attempts

  /// Sends `request`, and runs `answer` on a successful response. Until `answer` commits a status to
  /// the harness, a retryable failure is tried again after the policy's wait; after, the failure is
  /// `answer`'s to report in its own stream, and nothing else is written.
  private func attempt(
    _ request: EndpointHTTPRequest, token: String, route: GatewayRoute,
    writer: any GatewayResponseWriter,
    failed: (EndpointFailure, any GatewayResponseWriter) async -> Void,
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
        failure = error
      } catch is CancellationError {
        return
      } catch {
        failure = UnexpectedFailure.wrap(error)
      }
      if committed.isSet { return }
      guard let delay = retryPolicy.delay(after: number, failure: failure, waited: waited) else {
        await failed(failure, writer)
        return
      }
      await observer?.retrying(
        token: token, attempt: number + 1, of: retryPolicy.maximumAttempts, after: delay,
        failure: failure)
      do {
        try await sleep(delay)
      } catch {
        await failed(failure, writer)
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

/// A failure the gateway did not classify, from code that should only throw `EndpointFailure`.
enum UnexpectedFailure {
  static func wrap(_ error: any Error) -> EndpointFailure {
    EndpointFailure(kind: .server, message: "The gateway failed to read the answer.")
  }
}
