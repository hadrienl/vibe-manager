import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeEndpoints

@Suite("A custom protocol")
struct CustomProtocolTests {
  static let document = #"""
    {
      "schema": 1,
      "request": {"path": "agents/{{model}}/chat", "body": {
        "input": "{{lastUserText}}", "history": "{{messages:openai}}", "note": "for {{model}}",
        "stream": "{{stream}}"}},
      "stream": {"format": "ndjson"},
      "events": [
        {"when": {"path": "type", "equals": "delta"}, "text": "content"},
        {"when": {"path": "type", "equals": "tool"}, "toolCall": {"id": "id", "name": "name", "arguments": "args"}},
        {"when": {"path": "type", "equals": "step"}, "serverStep": {"name": "tool", "input": "input", "output": "result"}},
        {"when": {"path": "type", "equals": "done"}, "usage": {"input": "usage.in", "output": "usage.out"}, "stop": true},
        {"when": {"path": "type", "equals": "error"}, "error": "message"}
      ],
      "models": {"path": "agents", "list": "items", "id": "slug", "name": "title"}
    }
    """#

  @Test("A document is read, and a wrong one names where it is wrong")
  func parsing() throws {
    let document = try CustomProtocolDocument(parsing: Self.document)
    #expect(document.stream == .ndjson)
    #expect(document.rules.count == 5)
    #expect(document.operationPath(model: "support bot") == "agents/support%20bot/chat")

    let problems: [(String, String)] = [
      ("[]", "document"),
      (#"{"request":{}}"#, "request.path"),
      (#"{"request":{"path":"x"},"stream":{"format":"xml"},"events":[{"text":"a"}]}"#, "stream.format"),
      (#"{"request":{"path":"x"},"events":[{"when":{"path":"t"},"toolCall":{"id":"i"}}]}"#, "events[0].toolCall.name"),
      (#"{"request":{"path":"x"},"events":[{"stop":true}]}"#, "events"),
      (#"{"schema":9,"request":{"path":"x"},"events":[{"text":"a"}]}"#, "schema"),
    ]
    for (text, location) in problems {
      #expect(throws: CustomProtocolError.self) { try CustomProtocolDocument(parsing: text) }
      do {
        _ = try CustomProtocolDocument(parsing: text)
      } catch let error as CustomProtocolError {
        #expect(error.location == location, "\(text)")
      }
    }
  }

  @Test("The body is the template with the conversation put in it")
  func body() throws {
    let document = try CustomProtocolDocument(parsing: Self.document)
    let body = document.body(
      for: CanonicalRequest(
        model: "support",
        messages: [
          CanonicalMessage(role: .user, content: [.text("Hi")]),
          CanonicalMessage(role: .assistant, content: [.text("Hello")]),
          CanonicalMessage(role: .user, content: [.text("Where is A-12?")]),
        ]))
    #expect(body["input"] == "Where is A-12?")
    #expect(body["note"] == "for support")
    #expect(body["stream"] == true)
    #expect(body["history"]?.arrayValue?.count == 3)
  }

  @Test("An answer read by its rules: text streams, steps are steps, calls come whole at the end")
  func decoding() throws {
    var decoder = CustomProtocolDecoder(document: try CustomProtocolDocument(parsing: Self.document))
    var out: [CanonicalStreamEvent] = []
    for line in [
      #"{"type":"step","tool":"search_docs","input":{"q":"A-12"},"result":"found"}"#,
      #"{"type":"delta","content":"Looking"}"#,
      #"{"type":"tool","id":"t1","name":"Read","args":{"file_path":"/a"}}"#,
      #"{"type":"done","usage":{"in":30,"out":4}}"#,
    ] {
      out += try decoder.consume(ServerSentEvent(data: line))
    }
    out += try decoder.finish()
    #expect(
      out == [
        .start(id: "", model: ""),
        .serverStep(CanonicalServerStep(name: "search_docs", input: #"{"q":"A-12"}"#, output: "found")),
        .textStart(index: 0), .textDelta(index: 0, text: "Looking"), .blockStop(index: 0),
        .toolCallStart(index: 1, id: "t1", name: "Read"),
        .toolCallArgumentsDelta(index: 1, fragment: #"{"file_path":"/a"}"#), .blockStop(index: 1),
        .usage(CanonicalUsage(inputTokens: 30, outputTokens: 4)), .stop(.toolUse),
      ])
    #expect(throws: EndpointFailure.self) {
      try decoder.consume(ServerSentEvent(data: #"{"type":"error","message":"quota"}"#))
    }
  }

  @Test("Claude Code in front of a custom endpoint, its answer read line by line")
  func throughTheGateway() async throws {
    let transport = ScriptedTransport([
      .answer(
        status: 200, headers: [:],
        chunks: [
          #"{"type":"delta","content":"Hel"}"# + "\n" + #"{"type":"del"#,
          #"ta","content":"lo"}"# + "\n",
          #"{"type":"done","usage":{"in":5,"out":2}}"#,
        ], thenFail: nil)
    ])
    let routes = GatewayRouteTable()
    await routes.register(
      GatewayRoute(
        endpoint: EndpointConfiguration(
          baseURL: try #require(URL(string: "https://agents.example/api")), wireProtocol: .custom,
          customProtocol: try CustomProtocolDocument(parsing: Self.document)),
        secret: "k", model: "support"),
      token: "tok")
    let writer = RecordingWriter()
    await Gateway(routes: routes, transport: transport, sleep: { _ in }).handle(
      GatewayHTTPRequest(
        method: "POST", path: "/s/tok/v1/messages", headers: ["authorization": "Bearer tok"],
        body: Data(
          #"{"model":"x","max_tokens":10,"stream":true,"messages":[{"role":"user","content":"Hi"}]}"#
            .utf8)),
      writer: writer)
    let events = await writer.events
    let text = events.filter { $0.name == "content_block_delta" }.compactMap {
      try? JSONValue(parsing: $0.data)["delta"]?["text"]?.stringValue
    }.joined()
    #expect(text == "Hello")
    #expect(events.last?.name == "message_stop")
    #expect(transport.requests[0].url.absoluteString == "https://agents.example/api/agents/support/chat")
    #expect(try transport.sentBody(0)["input"] == "Hi")
  }

  private func customGateway(_ transport: ScriptedTransport, format: String = "ndjson") async throws
    -> Gateway
  {
    let routes = GatewayRouteTable()
    let document = Self.document.replacingOccurrences(
      of: #""format": "ndjson""#, with: "\"format\": \"\(format)\"")
    await routes.register(
      GatewayRoute(
        endpoint: EndpointConfiguration(
          baseURL: try #require(URL(string: "https://agents.example/api")), wireProtocol: .custom,
          customProtocol: try CustomProtocolDocument(parsing: document)),
        secret: nil, model: "support"),
      token: "tok")
    return Gateway(routes: routes, transport: transport, sleep: { _ in })
  }

  private func turn(stream: Bool) -> GatewayHTTPRequest {
    GatewayHTTPRequest(
      method: "POST", path: "/s/tok/v1/messages", headers: ["authorization": "Bearer tok"],
      body: Data(
        #"{"model":"x","max_tokens":10,"stream":\#(stream),"messages":[{"role":"user","content":"Hi"}]}"#
          .utf8))
  }

  @Test("The end is where the document says, not where the stream closes")
  func stopRule() async throws {
    // Heartbeats after the end are never read: the answer is complete at "done".
    let after = ScriptedTransport([
      .answer(
        status: 200, headers: [:],
        chunks: [
          #"{"type":"delta","content":"Hi"}"# + "\n" + #"{"type":"done"}"# + "\n",
          "not json at all\n",
        ], thenFail: nil)
    ])
    let complete = RecordingWriter()
    try await customGateway(after).handle(turn(stream: true), writer: complete)
    #expect(await complete.events.last?.name == "message_stop")

    // A stream closed before "done" was cut short, and is tried again.
    let cut = ScriptedTransport([
      .answer(status: 200, headers: [:], chunks: [#"{"type":"delta","content":"H"}"# + "\n"], thenFail: nil),
      .answer(
        status: 200, headers: [:],
        chunks: [#"{"type":"delta","content":"Hi"}"# + "\n" + #"{"type":"done"}"# + "\n"],
        thenFail: nil),
    ])
    let retried = RecordingWriter()
    try await customGateway(cut).handle(turn(stream: true), writer: retried)
    let events = await retried.events
    // The first answer had gone out before it was found cut: an error the harness retries.
    #expect(events.contains { $0.name == "error" })
  }

  @Test("A turn that does not stream, from a custom endpoint that streams, is answered whole")
  func wholeFromStream() async throws {
    let transport = ScriptedTransport([
      .answer(
        status: 200, headers: [:],
        chunks: [#"{"type":"delta","content":"Hello"}"# + "\n" + #"{"type":"done","usage":{"in":3,"out":1}}"# + "\n"],
        thenFail: nil)
    ])
    let writer = RecordingWriter()
    try await customGateway(transport).handle(turn(stream: false), writer: writer)
    let json = try #require(await writer.json)
    #expect(json["content"] == [["type": "text", "text": "Hello"]])
    #expect(json["usage"]?["input_tokens"] == 3)
  }

  @Test("A custom endpoint without a document that reads is not usable")
  func endpointMapping() {
    var endpoint = Endpoint(
      name: "Agents", baseURL: "https://agents.example/api", wireProtocol: .custom,
      models: [EndpointModel(id: "support")])
    #expect(endpoint.validationIssues == [.missingCustomProtocol])
    #expect(EndpointConfiguration(endpoint) == nil)
    endpoint.customProtocol = Self.document
    #expect(EndpointConfiguration(endpoint)?.customProtocol != nil)
    #expect(EndpointProber(transport: ScriptedTransport([])).customProtocolProblem("{}") != nil)
    #expect(EndpointProber(transport: ScriptedTransport([])).customProtocolProblem(Self.document) == nil)
  }

  @Test("Stored before custom endpoints existed, an endpoint reads with an empty document")
  func olderFile() throws {
    let stored = #"{"id":"7C1E6A55-0D5B-4E43-9E47-4A3C2B1D0E9F","name":"A","baseURL":"http://localhost:1","wireProtocol":"chatCompletions","authentication":{"none":{}}}"#
    let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(stored.utf8))
    #expect(endpoint.customProtocol.isEmpty)
    #expect(endpoint.models.isEmpty)
    #expect(endpoint.harness == .automatic)
  }
}
