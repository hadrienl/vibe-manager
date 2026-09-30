import Foundation
import Testing

@testable import VibeEndpoints

@Suite("Server-Sent Events")
struct ServerSentEventTests {
  @Test("Events split across chunks, CRLF, comments, multi-line data and a missing last blank line")
  func parsesAnyChunking() {
    let stream =
      ": keep-alive\r\nevent: a\r\ndata: one\r\ndata: two\r\n\r\ndata: {\"x\":1}\n\ndata: tail"
    var parser = ServerSentEventParser()
    var events: [ServerSentEvent] = []
    for byte in Array(stream.utf8) { events += parser.consume([byte]) }
    if let last = parser.finish() { events.append(last) }
    #expect(
      events == [
        ServerSentEvent(name: "a", data: "one\ntwo"), ServerSentEvent(data: #"{"x":1}"#),
        ServerSentEvent(data: "tail"),
      ])
  }

  @Test("A line that is no SSE field is kept apart, not lost")
  func strayLines() {
    var parser = ServerSentEventParser()
    _ = parser.consume(Data("data: [DONE]\n\n{\"object\":\"chat.completion\"}\n".utf8))
    #expect(parser.strayLines == [#"{"object":"chat.completion"}"#])
  }

  @Test("Encoding writes one data line per line and ends with a blank line")
  func encodes() {
    let encoded = String(
      decoding: ServerSentEvent(name: "ping", data: "a\nb").encoded, as: UTF8.self)
    #expect(encoded == "event: ping\ndata: a\ndata: b\n\n")
  }
}

@Suite("Claude Code's requests")
struct AnthropicRequestTests {
  static let claudeCodeRequest = #"""
    {"model":"claude-sonnet-5-5","max_tokens":32000,"stream":true,"temperature":1,
     "system":[{"type":"text","text":"You are Claude Code.","cache_control":{"type":"ephemeral"}},
               {"type":"text","text":"Be brief."}],
     "tools":[{"name":"Read","description":"Reads a file","input_schema":{"type":"object","properties":{"file_path":{"type":"string"}},"required":["file_path"]}},
              {"type":"web_search_20250305","name":"web_search","max_uses":5}],
     "tool_choice":{"type":"auto"},
     "thinking":{"type":"enabled","budget_tokens":4000},
     "messages":[
       {"role":"user","content":"Fix the test"},
       {"role":"assistant","content":[
          {"type":"thinking","thinking":"Look first.","signature":"vibe-gateway"},
          {"type":"text","text":"Reading it."},
          {"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/a.swift"}}]},
       {"role":"user","content":[
          {"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"let a = 1"}]},
          {"type":"text","text":"Go on","cache_control":{"type":"ephemeral"}}]}]}
    """#

  @Test("System parts joined, server tools dropped, blocks read in order")
  func decodes() throws {
    let request = try AnthropicMessagesServer.decodeRequest(
      JSONValue(parsing: Self.claudeCodeRequest))
    #expect(request.model == "claude-sonnet-5-5")
    #expect(request.system == "You are Claude Code.\n\nBe brief.")
    #expect(request.tools.map(\.name) == ["Read"])
    #expect(request.maxOutputTokens == 32_000)
    #expect(request.stream)
    #expect(request.messages.count == 3)
    #expect(
      request.messages[1].content == [
        .reasoning(text: "Look first.", signature: "vibe-gateway"), .text("Reading it."),
        .toolCall(id: "toolu_1", name: "Read", arguments: #"{"file_path":"/a.swift"}"#),
      ])
    #expect(
      request.messages[2].content == [
        .toolResult(callID: "toolu_1", content: [.text("let a = 1")], isError: false),
        .text("Go on"),
      ])
  }

  @Test("In Chat Completions, tool results come first, reasoning stays behind")
  func encodesChat() throws {
    let request = try AnthropicMessagesServer.decodeRequest(
      JSONValue(parsing: Self.claudeCodeRequest))
    let body = ChatCompletionsClient.encodeRequest(request)
    let messages = try #require(body["messages"]?.arrayValue)
    #expect(
      messages.map { $0["role"]?.stringValue } == ["system", "user", "assistant", "tool", "user"])
    #expect(messages[2]["content"] == "Reading it.")
    #expect(
      messages[2]["tool_calls"]
        == [
          [
            "id": "toolu_1", "type": "function",
            "function": ["name": "Read", "arguments": #"{"file_path":"/a.swift"}"#],
          ]
        ])
    #expect(messages[3] == ["role": "tool", "tool_call_id": "toolu_1", "content": "let a = 1"])
    #expect(messages[4] == ["role": "user", "content": "Go on"])
    #expect(body["stream_options"] == ["include_usage": true])
    #expect(body["tools"]?.arrayValue?.first?["function"]?["name"] == "Read")
    #expect(body["tool_choice"] == nil)
  }

  @Test(
    "A system message in the conversation, as Claude Code sends its reminders, reads as the user's")
  func systemMidConversation() throws {
    let request = try AnthropicMessagesServer.decodeRequest(
      JSONValue(
        parsing:
          #"{"model":"m","system":"Top","messages":[{"role":"user","content":[{"type":"text","text":"hi"}]},{"role":"system","content":[{"type":"text","text":"Reminder"}]}]}"#
      ))
    #expect(request.messages.map(\.role) == [.user, .system])
    let messages = ChatCompletionsClient.encodeRequest(request)["messages"]?.arrayValue ?? []
    #expect(
      messages == [
        ["role": "system", "content": "Top"], ["role": "user", "content": "hi\n\nReminder"],
      ])
  }

  @Test("A failed tool result says so, and its images follow as the user's")
  func errorResultAndImages() {
    let request = CanonicalRequest(
      model: "m",
      messages: [
        CanonicalMessage(
          role: .user,
          content: [
            .toolResult(
              callID: "c",
              content: [.text("no such file"), .image(mediaType: "image/png", base64: "AA")],
              isError: true)
          ])
      ])
    let messages = ChatCompletionsClient.encodeRequest(request)["messages"]?.arrayValue ?? []
    #expect(messages.first?["content"] == "Error: no such file")
    #expect(
      messages.last?["content"]
        == [["type": "image_url", "image_url": ["url": "data:image/png;base64,AA"]]])
  }
}

@Suite("Chat Completions answers")
struct ChatStreamTests {
  private func run(_ chunks: [String]) throws -> [CanonicalStreamEvent] {
    var parser = ServerSentEventParser()
    var decoder = ChatCompletionsStreamDecoder()
    var events: [CanonicalStreamEvent] = []
    for chunk in chunks {
      for event in parser.consume(Data(chunk.utf8)) { events += try decoder.consume(event) }
    }
    if let last = parser.finish() { events += try decoder.consume(last) }
    for line in parser.strayLines { events += decoder.consumeStray(line) }
    events += try decoder.finish()
    return events
  }

  @Test("Text streams, interleaved tool calls are handed over whole, usage and stop last")
  func textAndTools() throws {
    let events = try run([
      #"data: {"id":"gen-1","model":"qwen","choices":[{"index":0,"delta":{"role":"assistant","reasoning":"Hm."}}]}"#
        + "\n\n",
      #"data: {"id":"gen-1","choices":[{"index":0,"delta":{"content":"I'll look"}}]}"# + "\n\n",
      #"data: {"id":"gen-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"Read","arguments":"{\"file"}}]}}]}"#
        + "\n\n",
      #"data: {"id":"gen-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"Bash","arguments":"{\"command\":\"ls\"}"}}]}}]}"#
        + "\n\n",
      #"data: {"id":"gen-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"_path\":\"/a\"}"}}]}}]}"#
        + "\n\n",
      #"data: {"id":"gen-1","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#
        + "\n\n",
      #"data: {"id":"gen-1","choices":[],"usage":{"prompt_tokens":120,"completion_tokens":30,"prompt_tokens_details":{"cached_tokens":100}}}"#
        + "\n\n",
      "data: [DONE]\n\n",
    ])
    #expect(
      events == [
        .start(id: "gen-1", model: "qwen"),
        .reasoningStart(index: 0), .reasoningDelta(index: 0, text: "Hm."),
        .blockStop(index: 0),
        .textStart(index: 1), .textDelta(index: 1, text: "I'll look"),
        .blockStop(index: 1),
        .toolCallStart(index: 2, id: "call_a", name: "Read"),
        .toolCallArgumentsDelta(index: 2, fragment: #"{"file_path":"/a"}"#),
        .blockStop(index: 2),
        .toolCallStart(index: 3, id: "call_b", name: "Bash"),
        .toolCallArgumentsDelta(index: 3, fragment: #"{"command":"ls"}"#),
        .blockStop(index: 3),
        .usage(CanonicalUsage(inputTokens: 20, outputTokens: 30, cacheReadTokens: 100)),
        .stop(.toolUse),
      ])
  }

  @Test("The Prisme.ai LLM Gateway: the aggregated answer after [DONE] gives the usage only")
  func aggregatedAfterDone() throws {
    let aggregated =
      #"{"id":"x","object":"chat.completion","choices":[{"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#
    for trailer in ["data: \(aggregated)\n\n", aggregated + "\n"] {
      let events = try run([
        #"data: {"id":"x","choices":[{"delta":{"content":"Hello"}}]}"# + "\n\n",
        #"data: {"id":"x","choices":[{"delta":{},"finish_reason":"stop"}]}"# + "\n\n",
        "data: [DONE]\n\n", trailer,
      ])
      #expect(
        events.filter {
          guard case .textDelta = $0 else { return false }
          return true
        }.count == 1)
      #expect(
        events.suffix(2) == [
          .usage(CanonicalUsage(inputTokens: 10, outputTokens: 2)), .stop(.endTurn),
        ])
    }
  }

  @Test("A model that answers `stop` after a call still asked for a tool")
  func stopWithCalls() throws {
    let events = try run([
      #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"Read","arguments":""}}]},"finish_reason":"stop"}]}"#
        + "\n\n",
      "data: [DONE]\n\n",
    ])
    #expect(events.contains(.toolCallArgumentsDelta(index: 0, fragment: "{}")))
    #expect(events.last == .stop(.toolUse))
  }

  @Test("An error object in the stream fails the answer, with the endpoint's message")
  func embeddedError() {
    #expect(throws: EndpointFailure.self) {
      try run([#"data: {"error":{"message":"Provider returned error","code":502}}"# + "\n\n"])
    }
    do {
      _ = try run([#"data: {"error":{"message":"Rate limit exceeded","code":429}}"# + "\n\n"])
    } catch let failure as EndpointFailure {
      #expect(failure.kind == .rateLimited)
      #expect(failure.message.contains("Rate limit exceeded"))
    } catch {
      Issue.record("unexpected \(error)")
    }
  }

  @Test("Arguments cut short are closed; arguments that are not an object fail")
  func arguments() throws {
    #expect(
      try ChatCompletionsClient.validArguments(#"{"path":"/a","lines":[1,2"#)
        == #"{"path":"/a","lines":[1,2]}"#)
    #expect(try ChatCompletionsClient.validArguments(#"{"path":"/a\"#) == #"{"path":"/a"}"#)
    #expect(try ChatCompletionsClient.validArguments("  ") == "{}")
    #expect(throws: EndpointFailure.self) { try ChatCompletionsClient.validArguments("[1]") }
    #expect(throws: EndpointFailure.self) { try ChatCompletionsClient.validArguments("not json") }
  }

  @Test("An answer that does not stream reads the same")
  func whole() throws {
    let answer = try ChatCompletionsClient.decodeResponse(
      JSONValue(
        parsing:
          #"{"id":"a","model":"m","choices":[{"message":{"content":"","tool_calls":[{"id":"c","function":{"name":"Read","arguments":"{\"file_path\":\"/x\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":1}}"#
      ))
    #expect(answer.content == [.toolCall(id: "c", name: "Read", arguments: #"{"file_path":"/x"}"#)])
    #expect(answer.stopReason == .toolUse)
    #expect(answer.usage == CanonicalUsage(inputTokens: 5, outputTokens: 1))
  }
}

@Suite("Answers written for Claude Code")
struct AnthropicStreamTests {
  @Test("The Messages event sequence, byte for byte")
  func sequence() {
    var encoder = AnthropicMessagesStreamEncoder(id: "msg_x", model: "qwen")
    var out: [ServerSentEvent] = []
    for event: CanonicalStreamEvent in [
      .start(id: "msg_1", model: "qwen"), .textStart(index: 0), .textDelta(index: 0, text: "Hi"),
      .blockStop(index: 0), .toolCallStart(index: 1, id: "c", name: "Read"),
      .toolCallArgumentsDelta(index: 1, fragment: #"{"a":1}"#), .blockStop(index: 1),
      .usage(CanonicalUsage(inputTokens: 7, outputTokens: 3)), .stop(.toolUse),
    ] {
      out += encoder.encode(event)
    }
    out += encoder.finish()
    #expect(
      out.map(\.name) == [
        "message_start", "content_block_start", "content_block_delta", "content_block_stop",
        "content_block_start", "content_block_delta", "content_block_stop", "message_delta",
        "message_stop",
      ])
    #expect(
      out[0].data
        == #"{"message":{"content":[],"id":"msg_1","model":"qwen","role":"assistant","stop_reason":null,"stop_sequence":null,"type":"message","usage":{"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"input_tokens":0,"output_tokens":0}},"type":"message_start"}"#
    )
    #expect(
      out[5].data
        == #"{"delta":{"partial_json":"{\"a\":1}","type":"input_json_delta"},"index":1,"type":"content_block_delta"}"#
    )
    #expect(
      out[7].data
        == #"{"delta":{"stop_reason":"tool_use","stop_sequence":null},"type":"message_delta","usage":{"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"input_tokens":7,"output_tokens":3}}"#
    )
  }

  @Test("A failure mid-stream is an error event Claude Code retries")
  func failure() {
    var encoder = AnthropicMessagesStreamEncoder(id: "m", model: "q")
    _ = encoder.encode(.textStart(index: 0))
    let out = encoder.fail(EndpointFailure(kind: .network, message: "lost"))
    #expect(out.last?.name == "error")
    #expect(
      out.last?.data == #"{"error":{"message":"lost","type":"overloaded_error"},"type":"error"}"#)
  }

  @Test("Retryable failures are the ones Claude Code retries by itself")
  func statuses() {
    #expect(
      AnthropicMessagesServer.status(for: EndpointFailure(kind: .rateLimited, message: "")) == 429)
    #expect(
      AnthropicMessagesServer.status(for: EndpointFailure(kind: .timeout, message: "")) == 529)
    #expect(
      AnthropicMessagesServer.status(for: EndpointFailure(kind: .authentication, message: ""))
        == 401)
    #expect(
      AnthropicMessagesServer.status(for: EndpointFailure(kind: .contextTooLong, message: ""))
        == 400)
  }
}

@Suite("Endpoint failures")
struct EndpointFailureTests {
  @Test("Statuses and bodies classified, Retry-After read, messages cut to one line")
  func classifies() {
    let limited = EndpointFailure.http(
      status: 429, body: Data(#"{"error":{"message":"Slow down\nplease"}}"#.utf8), retryAfter: "12")
    #expect(limited.kind == .rateLimited)
    #expect(limited.retryAfter == .seconds(12))
    #expect(limited.message == "HTTP 429: Slow down")
    #expect(limited.isRetryable)
    let overflow = EndpointFailure.http(
      status: 400,
      body: Data(
        #"{"error":{"message":"This model's maximum context length is 32768 tokens"}}"#.utf8),
      retryAfter: nil)
    #expect(overflow.kind == .contextTooLong)
    #expect(!overflow.isRetryable)
    #expect(EndpointFailure.http(status: 503, body: Data(), retryAfter: nil).kind == .overloaded)
    #expect(EndpointFailure.http(status: 401, body: Data(), retryAfter: nil).message == "HTTP 401")
  }

  @Test("The retry policy doubles, honours Retry-After and keeps to its budget")
  func policy() {
    let policy = GatewayRetryPolicy(
      maximumAttempts: 4, baseDelay: .seconds(1), maximumDelay: .seconds(3), budget: .seconds(10))
    let busy = EndpointFailure(kind: .overloaded, message: "")
    #expect(policy.delay(after: 1, failure: busy, waited: .zero, jitter: 0) == .seconds(1))
    #expect(policy.delay(after: 2, failure: busy, waited: .zero, jitter: 0) == .seconds(2))
    #expect(policy.delay(after: 3, failure: busy, waited: .zero, jitter: 0) == .seconds(3))
    #expect(policy.delay(after: 4, failure: busy, waited: .zero, jitter: 0) == nil)
    let limited = EndpointFailure(kind: .rateLimited, message: "", retryAfter: .seconds(8))
    #expect(policy.delay(after: 1, failure: limited, waited: .zero, jitter: 0) == .seconds(8))
    #expect(policy.delay(after: 1, failure: limited, waited: .seconds(3), jitter: 0) == nil)
    #expect(
      policy.delay(
        after: 1, failure: EndpointFailure(kind: .authentication, message: ""), waited: .zero)
        == nil)
  }
}

@Suite("Endpoint URLs and headers")
struct EndpointConfigurationTests {
  @Test("Operations are appended once, whatever the user pasted")
  func urls() throws {
    for base in ["https://h/api/v1", "https://h/api/v1/", "https://h/api/v1/chat/completions"] {
      let configuration = EndpointConfiguration(
        baseURL: try #require(URL(string: base)), wireProtocol: .chatCompletions)
      #expect(
        configuration.url(for: "chat/completions", secret: nil).absoluteString
          == "https://h/api/v1/chat/completions")
    }
    let query = EndpointConfiguration(
      baseURL: try #require(URL(string: "https://h/v1beta?alt=sse")),
      wireProtocol: .chatCompletions,
      authentication: .query(name: "key"))
    #expect(
      query.url(for: "chat/completions", secret: "s3").absoluteString
        == "https://h/v1beta/chat/completions?alt=sse&key=s3")
  }

  @Test("Authentication first, the endpoint's own headers after")
  func headers() throws {
    let configuration = EndpointConfiguration(
      baseURL: try #require(URL(string: "https://h")), wireProtocol: .messages,
      authentication: .header(name: "x-api-key"), headers: ["X-Title": "Vibe Manager"])
    #expect(
      configuration.requestHeaders(secret: "k")
        == ["x-api-key": "k", "X-Title": "Vibe Manager"])
    #expect(
      EndpointConfiguration(
        baseURL: try #require(URL(string: "https://h")), wireProtocol: .messages
      )
      .requestHeaders(secret: nil).isEmpty)
  }
}
