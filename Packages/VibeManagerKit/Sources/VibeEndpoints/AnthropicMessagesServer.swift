import Foundation

/// The Anthropic Messages protocol as Claude Code speaks it to the gateway: its requests read into
/// the canonical shape, and the endpoint's answer written back as Messages events.
///
/// What is dropped, and why:
/// - `cache_control` marks: prompt caching is a property of Anthropic's servers, meaningless to
///   another endpoint, and harmless to lose.
/// - Tools without an `input_schema` (`web_search_20250305` and other server tools of Anthropic):
///   no other endpoint can run them, and offering one the model cannot call is worse than none.
/// - `document`, `search_result` and other block types the agent loop does not produce.
/// - `thinking` budgets: an endpoint that reasons decides how much by itself.
public enum AnthropicMessagesServer {
  public static func decodeRequest(_ body: JSONValue) throws -> CanonicalRequest {
    guard let model = body["model"]?.stringValue else {
      throw EndpointProtocolError.missingField("model")
    }
    guard let rawMessages = body["messages"]?.arrayValue else {
      throw EndpointProtocolError.missingField("messages")
    }
    var messages: [CanonicalMessage] = []
    for raw in rawMessages {
      guard let role = raw["role"]?.stringValue.flatMap(CanonicalMessage.Role.init(rawValue:))
      else { throw EndpointProtocolError.invalidField("messages.role") }
      messages.append(CanonicalMessage(role: role, content: try blocks(of: raw["content"])))
    }
    let tools: [CanonicalTool] = (body["tools"]?.arrayValue ?? []).compactMap { tool in
      guard let name = tool["name"]?.stringValue, let schema = tool["input_schema"] else {
        return nil
      }
      return CanonicalTool(
        name: name, description: tool["description"]?.stringValue, inputSchema: schema)
    }
    return CanonicalRequest(
      model: model,
      system: system(of: body["system"]),
      messages: messages,
      tools: tools,
      toolChoice: toolChoice(of: body["tool_choice"]),
      maxOutputTokens: body["max_tokens"]?.intValue,
      temperature: body["temperature"]?.numberValue,
      stream: body["stream"]?.boolValue ?? false)
  }

  private static func system(of value: JSONValue?) -> String? {
    switch value {
    case .string(let text):
      return text.isEmpty ? nil : text
    case .array(let parts):
      let texts = parts.compactMap { $0["text"]?.stringValue }.filter { !$0.isEmpty }
      return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    default:
      return nil
    }
  }

  private static func toolChoice(of value: JSONValue?) -> CanonicalToolChoice {
    switch value?["type"]?.stringValue {
    case "any": return .required
    case "none": return .none
    case "tool": return value?["name"]?.stringValue.map(CanonicalToolChoice.tool) ?? .auto
    default: return .auto
    }
  }

  static func blocks(of content: JSONValue?) throws -> [CanonicalBlock] {
    switch content {
    case .string(let text):
      return [.text(text)]
    case .array(let items):
      return try items.compactMap(block)
    case .none, .null?:
      return []
    default:
      throw EndpointProtocolError.invalidField("messages.content")
    }
  }

  private static func block(_ item: JSONValue) throws -> CanonicalBlock? {
    switch item["type"]?.stringValue {
    case "text":
      return .text(item["text"]?.stringValue ?? "")
    case "image":
      guard let image = image(item) else { return nil }
      return .image(mediaType: image.mediaType, base64: image.base64)
    case "tool_use":
      guard let id = item["id"]?.stringValue, let name = item["name"]?.stringValue else {
        throw EndpointProtocolError.invalidField("tool_use")
      }
      return .toolCall(id: id, name: name, arguments: (item["input"] ?? [:]).text())
    case "tool_result":
      guard let callID = item["tool_use_id"]?.stringValue else {
        throw EndpointProtocolError.invalidField("tool_result.tool_use_id")
      }
      return .toolResult(
        callID: callID, content: resultParts(item["content"]),
        isError: item["is_error"]?.boolValue ?? false)
    case "thinking":
      return .reasoning(
        text: item["thinking"]?.stringValue ?? "", signature: item["signature"]?.stringValue)
    default:
      return nil
    }
  }

  private static func resultParts(_ content: JSONValue?) -> [CanonicalResultPart] {
    switch content {
    case .string(let text):
      return [.text(text)]
    case .array(let items):
      return items.compactMap { item in
        switch item["type"]?.stringValue {
        case "text":
          return .text(item["text"]?.stringValue ?? "")
        case "image":
          return image(item).map { .image(mediaType: $0.mediaType, base64: $0.base64) }
        default:
          return nil
        }
      }
    default:
      return []
    }
  }

  private static func image(_ item: JSONValue) -> (mediaType: String, base64: String)? {
    guard let source = item["source"], source["type"]?.stringValue == "base64",
      let mediaType = source["media_type"]?.stringValue, let data = source["data"]?.stringValue
    else { return nil }
    return (mediaType, data)
  }

  // MARK: - Answers

  static func stopReason(_ reason: CanonicalStopReason) -> String {
    switch reason {
    case .endTurn: return "end_turn"
    case .toolUse: return "tool_use"
    case .maxTokens: return "max_tokens"
    case .stopSequence: return "stop_sequence"
    case .refusal: return "refusal"
    }
  }

  static func usage(_ usage: CanonicalUsage?) -> JSONValue {
    let usage = usage ?? CanonicalUsage()
    return [
      "input_tokens": .number(Double(usage.inputTokens)),
      "output_tokens": .number(Double(usage.outputTokens)),
      "cache_read_input_tokens": .number(Double(usage.cacheReadTokens)),
      "cache_creation_input_tokens": .number(Double(usage.cacheWriteTokens)),
    ]
  }

  /// Claude Code keeps the thinking blocks it is given and sends them back on the next turn. A
  /// signature is required there, and only Anthropic can issue a real one: blocks from another
  /// endpoint carry this marker instead, which the gateway recognises and drops on the way back.
  public static let foreignSignature = "vibe-gateway"

  static func block(_ block: CanonicalBlock) -> JSONValue? {
    switch block {
    case .text(let text):
      return ["type": "text", "text": .string(text)]
    case .toolCall(let id, let name, let arguments):
      let input = (try? JSONValue(parsing: arguments)) ?? [:]
      return ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
    case .reasoning(let text, let signature):
      return [
        "type": "thinking", "thinking": .string(text),
        "signature": .string(signature ?? foreignSignature),
      ]
    case .image, .toolResult:
      return nil
    }
  }

  public static func encodeResponse(_ response: CanonicalResponse) -> JSONValue {
    [
      "id": .string(response.id),
      "type": "message",
      "role": "assistant",
      "model": .string(response.model),
      "content": .array(response.content.compactMap(block)),
      "stop_reason": .string(stopReason(response.stopReason)),
      "stop_sequence": nil,
      "usage": usage(response.usage),
    ]
  }

  /// The body of an error, in the shape Claude Code reads and retries on.
  public static func errorBody(_ failure: EndpointFailure) -> JSONValue {
    [
      "type": "error",
      "error": ["type": .string(errorType(failure)), "message": .string(failure.message)],
    ]
  }

  /// The HTTP status Claude Code expects for this failure before any byte of a stream went out.
  public static func status(for failure: EndpointFailure) -> Int {
    switch failure.kind {
    case .authentication: return 401
    case .permission: return 403
    case .notFound: return 404
    case .rateLimited: return 429
    case .invalidRequest, .contextTooLong: return 400
    case .overloaded, .network, .timeout, .malformedResponse: return 529
    case .server: return 500
    }
  }

  static func errorType(_ failure: EndpointFailure) -> String {
    switch failure.kind {
    case .authentication: return "authentication_error"
    case .permission: return "permission_error"
    case .notFound: return "not_found_error"
    case .rateLimited: return "rate_limit_error"
    case .invalidRequest, .contextTooLong: return "invalid_request_error"
    // `overloaded_error` is the one Claude Code retries by itself, with its own backoff: a stream
    // cut in the middle, a silence, a garbled chunk are all worth another try.
    case .overloaded, .network, .timeout, .malformedResponse: return "overloaded_error"
    case .server: return "api_error"
    }
  }

  /// A rough count, for `count_tokens`: Claude Code asks it to decide when to compact, and no other
  /// endpoint answers it. Four characters a token is what the tokenizers of the models an agent
  /// runs on average for code and English; the endpoint's real count arrives with each answer.
  public static func estimatedInputTokens(_ request: CanonicalRequest) -> Int {
    var characters = request.system?.count ?? 0
    for message in request.messages {
      for block in message.content {
        switch block {
        case .text(let text): characters += text.count
        case .toolCall(_, let name, let arguments): characters += name.count + arguments.count
        case .toolResult(_, let parts, _):
          for part in parts {
            if case .text(let text) = part { characters += text.count } else { characters += 6_000 }
          }
        case .reasoning(let text, _): characters += text.count
        case .image: characters += 6_000
        }
      }
    }
    for tool in request.tools {
      characters += tool.name.count + (tool.description?.count ?? 0) + tool.inputSchema.text().count
    }
    return max(1, characters / 4)
  }
}

/// Writes canonical events as the Messages stream Claude Code reads.
public struct AnthropicMessagesStreamEncoder: Sendable {
  private var usage = CanonicalUsage()
  private var stopReason: CanonicalStopReason?
  private var started = false
  private var openBlocks: Set<Int> = []
  private let fallbackID: String
  private let fallbackModel: String

  public init(id: String, model: String) {
    fallbackID = id
    fallbackModel = model
  }

  public mutating func encode(_ event: CanonicalStreamEvent) -> [ServerSentEvent] {
    var out: [ServerSentEvent] = []
    if case .start = event {
    } else if !started {
      out += start(id: fallbackID, model: fallbackModel)
    }
    switch event {
    case .start(let id, let model):
      if !started { out += start(id: id.isEmpty ? fallbackID : id, model: model) }
    case .textStart(let index):
      out.append(blockStart(index, ["type": "text", "text": ""]))
    case .textDelta(let index, let text):
      out.append(delta(index, ["type": "text_delta", "text": .string(text)]))
    case .reasoningStart(let index):
      out.append(blockStart(index, ["type": "thinking", "thinking": "", "signature": ""]))
    case .reasoningDelta(let index, let text):
      out.append(delta(index, ["type": "thinking_delta", "thinking": .string(text)]))
    case .reasoningSignature(let index, let signature):
      out.append(delta(index, ["type": "signature_delta", "signature": .string(signature)]))
    case .toolCallStart(let index, let id, let name):
      out.append(
        blockStart(
          index, ["type": "tool_use", "id": .string(id), "name": .string(name), "input": [:]]))
    case .toolCallArgumentsDelta(let index, let fragment):
      out.append(delta(index, ["type": "input_json_delta", "partial_json": .string(fragment)]))
    case .blockStop(let index):
      out += stopBlock(index)
    case .serverStep:
      // Shown from the gateway's journal (#107 §4), never handed to Claude Code as a call to make.
      break
    case .usage(let usage):
      self.usage = usage
    case .stop(let reason):
      stopReason = reason
    }
    return out
  }

  /// The closing events: every block still open, the stop reason and the usage, then the end.
  public mutating func finish() -> [ServerSentEvent] {
    var out: [ServerSentEvent] = []
    if !started { out += start(id: fallbackID, model: fallbackModel) }
    for index in openBlocks.sorted() { out += stopBlock(index) }
    let reason = stopReason ?? .endTurn
    out.append(
      event(
        "message_delta",
        [
          "type": "message_delta",
          "delta": [
            "stop_reason": .string(AnthropicMessagesServer.stopReason(reason)),
            "stop_sequence": nil,
          ],
          "usage": AnthropicMessagesServer.usage(usage),
        ]))
    out.append(event("message_stop", ["type": "message_stop"]))
    return out
  }

  /// An error in the middle of the stream: Claude Code drops the partial answer and retries it
  /// when the type says so, without losing the turn.
  public mutating func fail(_ failure: EndpointFailure) -> [ServerSentEvent] {
    var out: [ServerSentEvent] = []
    if !started { out += start(id: fallbackID, model: fallbackModel) }
    out.append(event("error", AnthropicMessagesServer.errorBody(failure)))
    return out
  }

  private mutating func start(id: String, model: String) -> [ServerSentEvent] {
    started = true
    return [
      event(
        "message_start",
        [
          "type": "message_start",
          "message": [
            "id": .string(id), "type": "message", "role": "assistant", "model": .string(model),
            "content": [], "stop_reason": nil, "stop_sequence": nil,
            "usage": AnthropicMessagesServer.usage(nil),
          ],
        ])
    ]
  }

  private mutating func blockStart(_ index: Int, _ block: JSONValue) -> ServerSentEvent {
    openBlocks.insert(index)
    return event(
      "content_block_start",
      ["type": "content_block_start", "index": .number(Double(index)), "content_block": block])
  }

  private mutating func stopBlock(_ index: Int) -> [ServerSentEvent] {
    guard openBlocks.remove(index) != nil else { return [] }
    return [
      event("content_block_stop", ["type": "content_block_stop", "index": .number(Double(index))])
    ]
  }

  private func delta(_ index: Int, _ delta: JSONValue) -> ServerSentEvent {
    event(
      "content_block_delta",
      ["type": "content_block_delta", "index": .number(Double(index)), "delta": delta])
  }

  private func event(_ name: String, _ body: JSONValue) -> ServerSentEvent {
    ServerSentEvent(name: name, data: body.text())
  }
}
