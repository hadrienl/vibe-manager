import Foundation
import Testing

@testable import VibeEndpoints

@Suite("Codex's requests and answers")
struct ResponsesServerTests {
  static let codexRequest = #"""
    {"model":"gpt-5.5","instructions":"You are Codex.","stream":true,"store":false,
     "tool_choice":"auto","parallel_tool_calls":true,"include":["reasoning.encrypted_content"],
     "tools":[
       {"type":"function","name":"exec_command","description":"Runs a command","strict":false,
        "parameters":{"type":"object","properties":{"cmd":{"type":"string"}},"required":["cmd"]}},
       {"type":"custom","name":"apply_patch","description":"Edits files",
        "format":{"type":"grammar","syntax":"lark","definition":"start: patch"}},
       {"type":"web_search"}],
     "input":[
       {"type":"message","role":"developer","content":[{"type":"input_text","text":"Sandbox: workspace-write"}]},
       {"type":"message","role":"user","content":[{"type":"input_text","text":"Fix it"}]},
       {"type":"reasoning","summary":[],"encrypted_content":"gAAAA"},
       {"type":"function_call","call_id":"call_1","name":"exec_command","arguments":"{\"cmd\":\"ls\"}"},
       {"type":"function_call_output","call_id":"call_1","output":"a.swift"},
       {"type":"custom_tool_call","call_id":"call_2","name":"apply_patch","input":"*** Begin Patch"},
       {"type":"custom_tool_call_output","call_id":"call_2","output":"Done"}]}
    """#

  @Test(
    "Items grouped into turns, custom tools offered as functions of one string, the rest dropped")
  func decodes() throws {
    let decoded = try ResponsesServer.decodeRequest(JSONValue(parsing: Self.codexRequest))
    let request = decoded.request
    #expect(decoded.customTools == ["apply_patch"])
    #expect(request.system == "You are Codex.")
    #expect(request.tools.map(\.name) == ["exec_command", "apply_patch"])
    #expect(request.tools[1].inputSchema["required"] == ["input"])
    #expect(request.tools[1].description?.contains("start: patch") == true)
    #expect(request.messages.map(\.role) == [.system, .user, .assistant, .user, .assistant, .user])
    #expect(
      request.messages[4].content == [
        .toolCall(id: "call_2", name: "apply_patch", arguments: #"{"input":"*** Begin Patch"}"#)
      ])
    #expect(
      request.messages[5].content == [
        .toolResult(callID: "call_2", content: [.text("Done")], isError: false)
      ])
  }

  @Test("The Responses stream Codex reads: items added, deltas, items done, completion with usage")
  func encodesStream() throws {
    var encoder = ResponsesStreamEncoder(id: "resp_abcdefgh", model: "qwen", customTools: [])
    var out: [ServerSentEvent] = []
    for event: CanonicalStreamEvent in [
      .start(id: "x", model: "qwen"), .textStart(index: 0), .textDelta(index: 0, text: "Hi"),
      .blockStop(index: 0), .toolCallStart(index: 1, id: "call_9", name: "exec_command"),
      .toolCallArgumentsDelta(index: 1, fragment: #"{"cmd":"ls"}"#), .blockStop(index: 1),
      .usage(CanonicalUsage(inputTokens: 10, outputTokens: 4, cacheReadTokens: 5)), .stop(.toolUse),
    ] {
      out += encoder.encode(event)
    }
    out += encoder.finish()
    #expect(
      out.map(\.name) == [
        "response.created", "response.in_progress", "response.output_item.added",
        "response.content_part.added", "response.output_text.delta", "response.output_text.done",
        "response.content_part.done", "response.output_item.done", "response.output_item.added",
        "response.function_call_arguments.delta", "response.function_call_arguments.done",
        "response.output_item.done", "response.completed",
      ])
    let completed = try JSONValue(parsing: try #require(out.last).data)
    #expect(completed["response"]?["status"] == "completed")
    #expect(completed["response"]?["usage"]?["input_tokens"] == 15)
    #expect(completed["response"]?["usage"]?["input_tokens_details"]?["cached_tokens"] == 5)
    let call = try JSONValue(parsing: out[11].data)["item"]
    #expect(call?["type"] == "function_call")
    #expect(call?["call_id"] == "call_9")
    #expect(call?["arguments"] == #"{"cmd":"ls"}"#)
  }

  @Test("A call to a custom tool goes back to Codex as the custom call it offered")
  func customCall() throws {
    var encoder = ResponsesStreamEncoder(id: "resp_1", model: "m", customTools: ["apply_patch"])
    var out: [ServerSentEvent] = []
    for event: CanonicalStreamEvent in [
      .toolCallStart(index: 0, id: "c", name: "apply_patch"),
      .toolCallArgumentsDelta(index: 0, fragment: #"{"input":"*** Begin Patch\n*** End Patch"}"#),
      .blockStop(index: 0),
    ] {
      out += encoder.encode(event)
    }
    let done = try #require(out.first { $0.name == "response.output_item.done" })
    let item = try JSONValue(parsing: done.data)["item"]
    #expect(item?["type"] == "custom_tool_call")
    #expect(item?["input"] == "*** Begin Patch\n*** End Patch")
    #expect(!out.contains { $0.name == "response.function_call_arguments.delta" })
  }

  @Test("Cut short, the answer fails in a way Codex retries; errors before it carry its codes")
  func failures() throws {
    var encoder = ResponsesStreamEncoder(id: "r", model: "m", customTools: [])
    let failed = encoder.fail(EndpointFailure(kind: .rateLimited, message: "slow"))
    let body = try JSONValue(parsing: try #require(failed.last).data)
    #expect(body["type"] == "response.failed")
    #expect(body["response"]?["error"]?["code"] == "rate_limit_exceeded")
    #expect(ResponsesServer.status(for: EndpointFailure(kind: .timeout, message: "")) == 503)
    #expect(
      ResponsesServer.errorBody(EndpointFailure(kind: .contextTooLong, message: "big"))["error"]?[
        "code"] == "context_length_exceeded")
  }
}

@Suite("A Responses endpoint")
struct ResponsesClientTests {
  @Test("The conversation as items, with nothing stored on the endpoint")
  func encodes() {
    let body = ResponsesClient.encodeRequest(
      CanonicalRequest(
        model: "agent",
        system: "Be brief.",
        messages: [
          CanonicalMessage(role: .user, content: [.text("Hi")]),
          CanonicalMessage(
            role: .assistant,
            content: [.text("Looking"), .toolCall(id: "c1", name: "Read", arguments: "{}")]),
          CanonicalMessage(
            role: .user, content: [.toolResult(callID: "c1", content: [.text("x")], isError: false)]
          ),
        ],
        tools: [CanonicalTool(name: "Read", inputSchema: ["type": "object"])]))
    #expect(body["store"] == false)
    #expect(body["instructions"] == "Be brief.")
    #expect(
      body["input"]?.arrayValue?.map { $0["type"]?.stringValue ?? "" }
        == ["message", "message", "function_call", "function_call_output"])
    #expect(
      body["tools"] == [["type": "function", "name": "Read", "parameters": ["type": "object"]]])
  }

  @Test("An agent on the server: its hosted tools are steps, its function calls are the harness's")
  func serverAgent() throws {
    let events = [
      #"{"type":"response.created","response":{"id":"resp_1","model":"support-agent"}}"#,
      #"{"type":"response.output_item.added","output_index":0,"item":{"type":"file_search_call","id":"fs_1"}}"#,
      #"{"type":"response.output_item.done","output_index":0,"item":{"type":"file_search_call","id":"fs_1","queries":["linear keys"],"results":[{"text":"A-12"}]}}"#,
      #"{"type":"response.output_item.added","output_index":1,"item":{"type":"message","id":"m1"}}"#,
      #"{"type":"response.output_text.delta","output_index":1,"delta":"Found it."}"#,
      #"{"type":"response.output_item.done","output_index":1,"item":{"type":"message","id":"m1"}}"#,
      #"{"type":"response.output_item.added","output_index":2,"item":{"type":"function_call","call_id":"c7","name":"Read"}}"#,
      #"{"type":"response.function_call_arguments.delta","output_index":2,"delta":"{\"file_path\":\"/a\"}"}"#,
      #"{"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","call_id":"c7","name":"Read","arguments":"{\"file_path\":\"/a\"}"}}"#,
      #"{"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":50,"output_tokens":9,"input_tokens_details":{"cached_tokens":20}}}}"#,
    ]
    var decoder = ResponsesStreamDecoder()
    var out: [CanonicalStreamEvent] = []
    for event in events { out += try decoder.consume(ServerSentEvent(data: event)) }
    out += try decoder.finish()
    #expect(
      out == [
        .start(id: "resp_1", model: "support-agent"),
        .serverStep(
          CanonicalServerStep(
            name: "file_search", input: #"["linear keys"]"#, output: #"[{"text":"A-12"}]"#)),
        .textStart(index: 0), .textDelta(index: 0, text: "Found it."), .blockStop(index: 0),
        .toolCallStart(index: 1, id: "c7", name: "Read"),
        .toolCallArgumentsDelta(index: 1, fragment: #"{"file_path":"/a"}"#), .blockStop(index: 1),
        .usage(CanonicalUsage(inputTokens: 30, outputTokens: 9, cacheReadTokens: 20)),
        .stop(.toolUse),
      ])
  }

  @Test("A stream that ends before its completion is a failure worth retrying")
  func truncated() throws {
    var decoder = ResponsesStreamDecoder()
    _ = try decoder.consume(
      ServerSentEvent(data: #"{"type":"response.created","response":{"id":"r"}}"#))
    #expect(throws: EndpointFailure.self) { try decoder.finish() }
    #expect(throws: EndpointFailure.self) {
      try decoder.consume(
        ServerSentEvent(
          data:
            #"{"type":"response.failed","response":{"error":{"code":"rate_limit_exceeded","message":"x"}}}"#
        ))
    }
  }
}

@Suite("A Messages endpoint behind Codex")
struct AnthropicClientTests {
  @Test("Roles alternate, a later system message is the user's, max_tokens always set")
  func encodes() {
    let body = AnthropicMessagesClient.encodeRequest(
      CanonicalRequest(
        model: "claude",
        system: "Top",
        messages: [
          CanonicalMessage(role: .system, content: [.text("Sandbox")]),
          CanonicalMessage(role: .user, content: [.text("Hi")]),
          CanonicalMessage(
            role: .assistant, content: [.toolCall(id: "c", name: "ls", arguments: "{}")]),
          CanonicalMessage(
            role: .user, content: [.toolResult(callID: "c", content: [.text("a")], isError: false)]),
          CanonicalMessage(role: .system, content: [.text("Reminder")]),
        ]),
      defaultMaximumTokens: nil)
    #expect(body["system"] == "Top\n\nSandbox")
    #expect(body["max_tokens"] == 16_384)
    let messages = body["messages"]?.arrayValue ?? []
    #expect(messages.map { $0["role"]?.stringValue ?? "" } == ["user", "assistant", "user"])
    #expect(messages[2]["content"]?.arrayValue?.count == 2)
    #expect(messages[1]["content"]?.arrayValue?.first?["input"] == [:])
  }

  @Test("Server tools become steps, blocks renumbered, usage from start and end")
  func decodesStream() throws {
    let events = [
      #"{"type":"message_start","message":{"id":"msg_1","model":"claude","usage":{"input_tokens":40,"output_tokens":1}}}"#,
      #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv_1","name":"web_search"}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"x\"}"}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srv_1","content":[]}}"#,
      #"{"type":"content_block_stop","index":1}"#,
      #"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Done"}}"#,
      #"{"type":"content_block_stop","index":2}"#,
      #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
      #"{"type":"message_stop"}"#,
    ]
    var decoder = AnthropicMessagesStreamDecoder()
    var out: [CanonicalStreamEvent] = []
    for event in events { out += try decoder.consume(ServerSentEvent(data: event)) }
    out += try decoder.finish()
    #expect(
      out == [
        .start(id: "msg_1", model: "claude"),
        .serverStep(
          CanonicalServerStep(name: "web_search", input: #"{"query":"x"}"#, output: "[]")),
        .textStart(index: 0), .textDelta(index: 0, text: "Done"), .blockStop(index: 0),
        .usage(CanonicalUsage(inputTokens: 40, outputTokens: 5)), .stop(.endTurn),
      ])
  }

  @Test("An error event fails with its kind")
  func error() {
    var decoder = AnthropicMessagesStreamDecoder()
    do {
      _ = try decoder.consume(
        ServerSentEvent(
          data: #"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#))
      Issue.record("no failure")
    } catch let failure as EndpointFailure {
      #expect(failure.kind == .overloaded)
    } catch {
      Issue.record("unexpected \(error)")
    }
  }
}

@Suite("The gateway between Codex and an endpoint")
struct CodexGatewayTests {
  @Test("Codex in front of Chat Completions: a Responses stream, custom tools answered as such")
  func codexOverChat() async throws {
    let transport = ScriptedTransport([
      .answer(
        status: 200, headers: [:],
        chunks: [
          #"data: {"id":"g","choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"apply_patch","arguments":"{\"input\":\"*** Begin Patch\"}"}}]},"finish_reason":"tool_calls"}]}"#
            + "\n\n",
          "data: [DONE]\n\n",
        ], thenFail: nil)
    ])
    let routes = GatewayRouteTable()
    await routes.register(
      GatewayRoute(
        endpoint: EndpointConfiguration(
          baseURL: try #require(URL(string: "http://localhost:11434/v1")),
          wireProtocol: .chatCompletions, authentication: .none),
        secret: nil, model: "qwen3-coder:30b"),
      token: "tok")
    let gateway = Gateway(routes: routes, transport: transport, sleep: { _ in })
    let writer = RecordingWriter()
    await gateway.handle(
      GatewayHTTPRequest(
        method: "POST", path: "/s/tok/v1/responses", headers: ["authorization": "Bearer tok"],
        body: Data(ResponsesServerTests.codexRequest.utf8)),
      writer: writer)
    let events = await writer.events
    #expect(events.first?.name == "response.created")
    #expect(events.last?.name == "response.completed")
    let item = try JSONValue(
      parsing: try #require(events.first { $0.name == "response.output_item.done" }).data)["item"]
    #expect(item?["type"] == "custom_tool_call")
    #expect(item?["input"] == "*** Begin Patch")
    let sent = try transport.sentBody(0)
    #expect(sent["model"] == "qwen3-coder:30b")
    #expect(transport.requests[0].headers["Authorization"] == nil)
  }

  @Test("An unknown token answers in Codex's own error shape")
  func unknownToken() async throws {
    let gateway = Gateway(routes: GatewayRouteTable(), transport: ScriptedTransport([]))
    let writer = RecordingWriter()
    await gateway.handle(
      GatewayHTTPRequest(method: "POST", path: "/s/nope/v1/responses"), writer: writer)
    #expect(await writer.status == 401)
    #expect(await writer.json?["error"]?["code"] == "invalid_api_key")
  }
}
