import Foundation

/// The OpenAI Chat Completions protocol as the gateway speaks it to an endpoint.
///
/// The most widespread protocol, and the loosest: OpenRouter, Ollama, LM Studio, vLLM, LiteLLM and
/// the Prisme.ai LLM Gateway all speak it, each with its own liberties. The reader below accepts
/// what they were seen to send rather than what the specification says.
public enum ChatCompletionsClient {
  public static let path = "chat/completions"

  public static func encodeRequest(_ request: CanonicalRequest) -> JSONValue {
    var messages: [JSONValue] = []
    if let system = request.system {
      messages.append(["role": "system", "content": .string(system)])
    }
    for message in request.messages {
      switch message.role {
      case .assistant: messages += assistant(message.content)
      case .user: messages += user(message.content)
      case .system:
        let text = message.content.compactMap { block -> String? in
          if case .text(let text) = block { return text }
          return nil
        }.joined(separator: "\n\n")
        guard !text.isEmpty else { continue }
        // Many chat templates refuse a system message anywhere but first: one that comes later is
        // given as the user's words, which is how the model would have read it anyway.
        if messages.allSatisfy({ $0["role"]?.stringValue == "system" }) {
          messages.append(["role": "system", "content": .string(text)])
        } else {
          messages.append(["role": "user", "content": .string(text)])
        }
      }
    }
    messages = coalesced(messages)
    var body: [String: JSONValue] = [
      "model": .string(request.model),
      "messages": .array(messages),
      "stream": .bool(request.stream),
    ]
    if request.stream {
      // Without it, most endpoints send no usage at all in a stream.
      body["stream_options"] = ["include_usage": true]
    }
    if !request.tools.isEmpty {
      body["tools"] = .array(
        request.tools.map { tool in
          var function: [String: JSONValue] = [
            "name": .string(tool.name), "parameters": tool.inputSchema,
          ]
          if let description = tool.description { function["description"] = .string(description) }
          return ["type": "function", "function": .object(function)]
        })
      switch request.toolChoice {
      case .auto: break
      case .none: body["tool_choice"] = "none"
      case .required: body["tool_choice"] = "required"
      case .tool(let name):
        body["tool_choice"] = ["type": "function", "function": ["name": .string(name)]]
      }
    }
    if let maxOutputTokens = request.maxOutputTokens {
      body["max_tokens"] = .number(Double(maxOutputTokens))
    }
    if let temperature = request.temperature { body["temperature"] = .number(temperature) }
    return .object(body)
  }

  /// Consecutive system messages, and consecutive user messages of plain text, as one: some
  /// templates require roles to alternate.
  private static func coalesced(_ messages: [JSONValue]) -> [JSONValue] {
    var result: [JSONValue] = []
    for message in messages {
      if let last = result.last, let role = message["role"]?.stringValue,
        role == last["role"]?.stringValue, role == "system" || role == "user",
        let previous = last["content"]?.stringValue, let text = message["content"]?.stringValue
      {
        result[result.count - 1] = [
          "role": .string(role), "content": .string(previous + "\n\n" + text),
        ]
      } else {
        result.append(message)
      }
    }
    return result
  }

  private static func assistant(_ blocks: [CanonicalBlock]) -> [JSONValue] {
    var text = ""
    var calls: [JSONValue] = []
    for block in blocks {
      switch block {
      case .text(let part):
        text += part
      case .toolCall(let id, let name, let arguments):
        calls.append(
          [
            "id": .string(id), "type": "function",
            "function": ["name": .string(name), "arguments": .string(arguments)],
          ])
      case .reasoning, .image, .toolResult:
        // Reasoning belongs to the model that wrote it; replaying it to another is at best noise.
        continue
      }
    }
    // An empty string rather than `null` beside tool calls: OpenAI takes either, and stricter
    // validators — the Prisme.ai LLM Gateway's — only a string or an array.
    var message: [String: JSONValue] = ["role": "assistant", "content": .string(text)]
    if !calls.isEmpty { message["tool_calls"] = .array(calls) }
    return [.object(message)]
  }

  /// Results of tool calls become `tool` messages, which must come right after the assistant
  /// message that asked for them, before any other user text: the Messages protocol puts both in
  /// one user turn, Chat Completions splits it in that order.
  private static func user(_ blocks: [CanonicalBlock]) -> [JSONValue] {
    var messages: [JSONValue] = []
    var parts: [JSONValue] = []
    for block in blocks {
      switch block {
      case .toolResult(let callID, let content, let isError):
        var text = ""
        for part in content {
          switch part {
          case .text(let value): text += value
          case .image(let mediaType, let base64):
            // A tool message carries text only: its images follow as the user's.
            parts.append(imagePart(mediaType: mediaType, base64: base64))
          }
        }
        if isError, !text.hasPrefix("Error") { text = "Error: " + text }
        messages.append(["role": "tool", "tool_call_id": .string(callID), "content": .string(text)])
      case .text(let text):
        parts.append(["type": "text", "text": .string(text)])
      case .image(let mediaType, let base64):
        parts.append(imagePart(mediaType: mediaType, base64: base64))
      case .toolCall, .reasoning:
        continue
      }
    }
    if !parts.isEmpty {
      let onlyText = parts.allSatisfy { $0["type"]?.stringValue == "text" }
      let content: JSONValue =
        onlyText
        ? .string(parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n\n"))
        : .array(parts)
      messages.append(["role": "user", "content": content])
    }
    return messages
  }

  private static func imagePart(mediaType: String, base64: String) -> JSONValue {
    ["type": "image_url", "image_url": ["url": .string("data:\(mediaType);base64,\(base64)")]]
  }

  // MARK: - Whole answers

  public static func decodeResponse(_ body: JSONValue) throws -> CanonicalResponse {
    if let failure = embeddedFailure(body) { throw failure }
    guard let choice = body["choices"]?.arrayValue?.first, let message = choice["message"] else {
      throw EndpointProtocolError.missingField("choices")
    }
    var content: [CanonicalBlock] = []
    if let reasoning = reasoningText(message), !reasoning.isEmpty {
      content.append(.reasoning(text: reasoning, signature: nil))
    }
    if let text = message["content"]?.stringValue, !text.isEmpty { content.append(.text(text)) }
    let calls = message["tool_calls"]?.arrayValue ?? []
    for (offset, call) in calls.enumerated() {
      let name = call["function"]?["name"]?.stringValue ?? ""
      let arguments = call["function"]?["arguments"]?.stringValue ?? ""
      content.append(
        .toolCall(
          id: call["id"]?.stringValue ?? "call_\(offset)", name: name,
          arguments: try validArguments(arguments)))
    }
    return CanonicalResponse(
      id: body["id"]?.stringValue ?? "",
      model: body["model"]?.stringValue ?? "",
      content: content,
      stopReason: stopReason(choice["finish_reason"]?.stringValue, hasToolCalls: !calls.isEmpty),
      usage: usage(body["usage"]))
  }

  static func reasoningText(_ message: JSONValue) -> String? {
    // DeepSeek and vLLM say `reasoning_content`, OpenRouter and Ollama `reasoning`.
    message["reasoning_content"]?.stringValue ?? message["reasoning"]?.stringValue
  }

  static func stopReason(_ finish: String?, hasToolCalls: Bool) -> CanonicalStopReason {
    // Several local servers answer `stop` after a tool call: the calls are what count.
    if hasToolCalls { return .toolUse }
    switch finish {
    case "length": return .maxTokens
    case "content_filter": return .refusal
    case "tool_calls", "function_call": return .toolUse
    default: return .endTurn
    }
  }

  static func usage(_ value: JSONValue?) -> CanonicalUsage? {
    guard let value, let fields = value.objectValue, !fields.isEmpty else { return nil }
    let cached = value["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0
    let prompt = value["prompt_tokens"]?.intValue ?? 0
    return CanonicalUsage(
      // The Messages protocol counts cached input apart from the rest.
      inputTokens: max(0, prompt - cached),
      outputTokens: value["completion_tokens"]?.intValue ?? 0,
      cacheReadTokens: cached,
      reasoningTokens: value["completion_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0)
  }

  /// An `error` object in a body that came with a success status: OpenRouter sends one mid-stream,
  /// others instead of an answer.
  static func embeddedFailure(_ body: JSONValue) -> EndpointFailure? {
    guard let error = body["error"], !error.isNull else { return nil }
    let message = error["message"]?.stringValue ?? error.stringValue ?? "error"
    let code = error["code"]?.intValue ?? error["status"]?.intValue
    if let code, code >= 400 {
      return EndpointFailure.http(
        status: code, body: JSONValue.object(["error": ["message": .string(message)]]).data(),
        retryAfter: nil)
    }
    let kind: EndpointFailure.Kind =
      EndpointFailure.looksLikeContextOverflow(message) ? .contextTooLong : .server
    return EndpointFailure(kind: kind, message: message)
  }

  /// The arguments of a call, made valid JSON when only their end is missing, as a stream cut
  /// short or a small model leaves them.
  static func validArguments(_ arguments: String) throws -> String {
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "{}" }
    if (try? JSONValue(parsing: trimmed))?.objectValue != nil { return trimmed }
    if let repaired = JSONRepair.closing(trimmed),
      (try? JSONValue(parsing: repaired))?.objectValue != nil
    {
      return repaired
    }
    throw EndpointFailure(
      kind: .malformedResponse, message: "The model wrote arguments that are not a JSON object.")
  }
}

/// Reads a Chat Completions stream into canonical events.
///
/// Text and reasoning are passed on as they arrive. Tool calls are gathered and handed over whole
/// when the answer ends: their arguments arrive in fragments that endpoints interleave between
/// calls, which the Messages protocol cannot express, and a call is only useful to the harness once
/// complete anyway. It is also the only moment their JSON can be checked and repaired.
public struct ChatCompletionsStreamDecoder: Sendable {
  private struct PendingCall: Sendable {
    var id: String
    var name: String
    var arguments: String
  }

  private var started = false
  private var nextIndex = 0
  private var openIndex: Int?
  private var openKind: OpenKind?
  private var calls: [Int: PendingCall] = [:]
  private var callOrder: [Int] = []
  private var finishReason: String?
  private var usage: CanonicalUsage?
  private var sawDone = false
  private var finished = false

  private enum OpenKind: Sendable {
    case text
    case reasoning
  }

  public init() {}

  /// Whether `data: [DONE]` arrived. An endpoint may keep writing after it, and the Prisme.ai LLM
  /// Gateway does, with the whole answer and its usage.
  public var isDone: Bool { sawDone }

  public mutating func consume(_ event: ServerSentEvent) throws -> [CanonicalStreamEvent] {
    let data = event.data.trimmingCharacters(in: .whitespaces)
    if data == "[DONE]" {
      sawDone = true
      return []
    }
    guard !data.isEmpty, let chunk = try? JSONValue(parsing: data) else {
      if sawDone { return [] }
      throw EndpointFailure(
        kind: .malformedResponse, message: "The endpoint sent a stream event that is not JSON.")
    }
    return try consume(chunk)
  }

  /// A line that is not an SSE field: the aggregated answer some endpoints write after `[DONE]`.
  public mutating func consumeStray(_ line: String) -> [CanonicalStreamEvent] {
    guard let chunk = try? JSONValue(parsing: line) else { return [] }
    return (try? consume(chunk)) ?? []
  }

  public mutating func consume(_ chunk: JSONValue) throws -> [CanonicalStreamEvent] {
    if let failure = ChatCompletionsClient.embeddedFailure(chunk) { throw failure }
    var out: [CanonicalStreamEvent] = []
    if !started {
      started = true
      out.append(
        .start(id: chunk["id"]?.stringValue ?? "", model: chunk["model"]?.stringValue ?? ""))
    }
    if let usage = ChatCompletionsClient.usage(chunk["usage"]) { self.usage = usage }
    // The aggregated answer, after `[DONE]`: its usage is taken, its content was already streamed.
    if sawDone || chunk["object"]?.stringValue == "chat.completion" { return out }
    guard let choice = chunk["choices"]?.arrayValue?.first else { return out }
    let delta = choice["delta"] ?? choice["message"] ?? [:]
    if let reasoning = ChatCompletionsClient.reasoningText(delta), !reasoning.isEmpty {
      out += append(reasoning, as: .reasoning)
    }
    if let text = delta["content"]?.stringValue, !text.isEmpty {
      out += append(text, as: .text)
    }
    for call in delta["tool_calls"]?.arrayValue ?? [] {
      let position = call["index"]?.intValue ?? callOrder.count
      var pending = calls[position] ?? PendingCall(id: "", name: "", arguments: "")
      if calls[position] == nil { callOrder.append(position) }
      if let id = call["id"]?.stringValue, !id.isEmpty { pending.id = id }
      if let name = call["function"]?["name"]?.stringValue, !name.isEmpty {
        pending.name = pending.name.isEmpty ? name : pending.name
      }
      if let fragment = call["function"]?["arguments"]?.stringValue {
        pending.arguments += fragment
      }
      calls[position] = pending
    }
    if let finish = choice["finish_reason"]?.stringValue { finishReason = finish }
    return out
  }

  private mutating func append(_ text: String, as kind: OpenKind) -> [CanonicalStreamEvent] {
    var out: [CanonicalStreamEvent] = []
    if openKind != kind {
      out += closeOpenBlock()
      let index = nextIndex
      nextIndex += 1
      openIndex = index
      openKind = kind
      out.append(kind == .text ? .textStart(index: index) : .reasoningStart(index: index))
    }
    guard let index = openIndex else { return out }
    out.append(
      kind == .text
        ? .textDelta(index: index, text: text) : .reasoningDelta(index: index, text: text))
    return out
  }

  private mutating func closeOpenBlock() -> [CanonicalStreamEvent] {
    defer {
      openIndex = nil
      openKind = nil
    }
    guard let index = openIndex else { return [] }
    return [.blockStop(index: index)]
  }

  /// The end of the answer: open blocks closed, calls handed over, usage and stop reason.
  public mutating func finish() throws -> [CanonicalStreamEvent] {
    guard !finished else { return [] }
    finished = true
    guard started else {
      throw EndpointFailure(kind: .malformedResponse, message: "The endpoint sent no answer.")
    }
    var out = closeOpenBlock()
    for position in callOrder {
      guard let call = calls[position] else { continue }
      guard !call.name.isEmpty else {
        throw EndpointFailure(
          kind: .malformedResponse, message: "The model called a tool without naming it.")
      }
      let index = nextIndex
      nextIndex += 1
      let id = call.id.isEmpty ? "call_\(UUID().uuidString.prefix(12))" : call.id
      out.append(.toolCallStart(index: index, id: id, name: call.name))
      out.append(
        .toolCallArgumentsDelta(
          index: index, fragment: try ChatCompletionsClient.validArguments(call.arguments)))
      out.append(.blockStop(index: index))
    }
    if let usage { out.append(.usage(usage)) }
    out.append(
      .stop(ChatCompletionsClient.stopReason(finishReason, hasToolCalls: !callOrder.isEmpty)))
    return out
  }
}

/// Closes what a JSON text left open, when only its end is missing.
enum JSONRepair {
  static func closing(_ text: String) -> String? {
    var stack: [Character] = []
    var inString = false
    var escaped = false
    for character in text {
      if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
        continue
      }
      switch character {
      case "\"": inString = true
      case "{": stack.append("}")
      case "[": stack.append("]")
      case "}", "]":
        guard stack.last == character else { return nil }
        stack.removeLast()
      default: break
      }
    }
    guard inString || !stack.isEmpty else { return nil }
    var repaired = text
    if escaped { repaired.removeLast() }
    if inString { repaired += "\"" }
    // A dangling separator cannot be closed into anything valid.
    while let last = repaired.last, last == "," || last == ":" || last.isWhitespace {
      repaired.removeLast()
    }
    repaired += String(stack.reversed())
    return repaired
  }
}
