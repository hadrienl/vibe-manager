import Foundation

/// The Anthropic Messages protocol as the gateway speaks it to an endpoint, when the harness is
/// not Claude Code: Codex in front of an Anthropic-compatible endpoint (Ollama, a corporate gateway).
///
/// The protocol wants roles that alternate, a `max_tokens` on every request, and tool results in
/// the user turn right after the calls: consecutive turns of one role are merged into one.
public enum AnthropicMessagesClient {
  /// Used when the harness does not say: enough for an agent's turn, accepted by every current
  /// model. An endpoint that allows less says so through its default parameters.
  public static let defaultMaximumTokens = 16_384

  public static func encodeRequest(_ request: CanonicalRequest, defaultMaximumTokens: Int?)
    -> JSONValue
  {
    var messages: [(role: String, content: [JSONValue])] = []
    func add(_ role: String, _ blocks: [JSONValue]) {
      guard !blocks.isEmpty else { return }
      if let last = messages.last, last.role == role {
        messages[messages.count - 1].content += blocks
      } else {
        messages.append((role, blocks))
      }
    }
    var systemTexts: [String] = request.system.map { [$0] } ?? []
    for message in request.messages {
      let blocks = message.content.compactMap(block)
      switch message.role {
      case .assistant:
        add("assistant", blocks)
      case .user:
        add("user", blocks)
      case .system:
        // Instructions before the conversation start join the system prompt; later ones are
        // given as the user's words, which every model accepts.
        if messages.isEmpty {
          systemTexts += blocks.compactMap { $0["text"]?.stringValue }
        } else {
          add("user", blocks)
        }
      }
    }
    var body: [String: JSONValue] = [
      "model": .string(request.model),
      "messages": .array(
        messages.map { ["role": .string($0.role), "content": .array($0.content)] }),
      "max_tokens": .number(
        Double(request.maxOutputTokens ?? defaultMaximumTokens ?? Self.defaultMaximumTokens)),
      "stream": .bool(request.stream),
    ]
    if !systemTexts.isEmpty { body["system"] = .string(systemTexts.joined(separator: "\n\n")) }
    if !request.tools.isEmpty {
      body["tools"] = .array(
        request.tools.map { tool in
          var fields: [String: JSONValue] = [
            "name": .string(tool.name), "input_schema": tool.inputSchema,
          ]
          if let description = tool.description { fields["description"] = .string(description) }
          return .object(fields)
        })
      switch request.toolChoice {
      case .auto: break
      case .none: body["tool_choice"] = ["type": "none"]
      case .required: body["tool_choice"] = ["type": "any"]
      case .tool(let name): body["tool_choice"] = ["type": "tool", "name": .string(name)]
      }
    }
    if let temperature = request.temperature { body["temperature"] = .number(temperature) }
    return .object(body)
  }

  private static func block(_ block: CanonicalBlock) -> JSONValue? {
    switch block {
    case .text(let text):
      return text.isEmpty ? nil : ["type": "text", "text": .string(text)]
    case .image(let mediaType, let base64):
      return [
        "type": "image",
        "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(base64)],
      ]
    case .toolCall(let id, let name, let arguments):
      return [
        "type": "tool_use", "id": .string(id), "name": .string(name),
        "input": (try? JSONValue(parsing: arguments)) ?? [:],
      ]
    case .toolResult(let callID, let content, let isError):
      let parts: [JSONValue] = content.map { part in
        switch part {
        case .text(let text): return ["type": "text", "text": .string(text)]
        case .image(let mediaType, let base64):
          return [
            "type": "image",
            "source": [
              "type": "base64", "media_type": .string(mediaType), "data": .string(base64),
            ],
          ]
        }
      }
      return [
        "type": "tool_result", "tool_use_id": .string(callID), "content": .array(parts),
        "is_error": .bool(isError),
      ]
    case .reasoning:
      // Thinking is only replayed with a signature Anthropic issued, and only to the model that
      // wrote it; the gateway never asks for thinking, so it has none to replay.
      return nil
    }
  }

  static func stopReason(_ value: String?) -> CanonicalStopReason {
    switch value {
    case "tool_use": return .toolUse
    case "max_tokens": return .maxTokens
    case "stop_sequence": return .stopSequence
    case "refusal": return .refusal
    default: return .endTurn
    }
  }

  static func usage(_ value: JSONValue?, into usage: inout CanonicalUsage) {
    guard let value else { return }
    if let input = value["input_tokens"]?.intValue { usage.inputTokens = input }
    if let output = value["output_tokens"]?.intValue { usage.outputTokens = output }
    if let read = value["cache_read_input_tokens"]?.intValue { usage.cacheReadTokens = read }
    if let write = value["cache_creation_input_tokens"]?.intValue { usage.cacheWriteTokens = write }
  }

  public static func decodeResponse(_ body: JSONValue) throws -> CanonicalResponse {
    if body["type"]?.stringValue == "error" {
      throw failure(body["error"])
    }
    var content: [CanonicalBlock] = []
    var steps: [CanonicalServerStep] = []
    var pendingServerCalls: [String: (name: String, input: String)] = [:]
    for item in body["content"]?.arrayValue ?? [] {
      switch item["type"]?.stringValue {
      case "text":
        content.append(.text(item["text"]?.stringValue ?? ""))
      case "thinking":
        content.append(
          .reasoning(
            text: item["thinking"]?.stringValue ?? "", signature: item["signature"]?.stringValue))
      case "tool_use":
        content.append(
          .toolCall(
            id: item["id"]?.stringValue ?? "", name: item["name"]?.stringValue ?? "",
            arguments: (item["input"] ?? [:]).text()))
      case "server_tool_use", "mcp_tool_use":
        pendingServerCalls[item["id"]?.stringValue ?? ""] = (
          item["name"]?.stringValue ?? "tool", (item["input"] ?? [:]).text()
        )
      case let type? where type.hasSuffix("_tool_result"):
        let id = item["tool_use_id"]?.stringValue ?? ""
        let call = pendingServerCalls.removeValue(forKey: id)
        steps.append(
          CanonicalServerStep(
            name: call?.name ?? type, input: call?.input, output: item["content"]?.text()))
      default:
        continue
      }
    }
    var usage = CanonicalUsage()
    Self.usage(body["usage"], into: &usage)
    return CanonicalResponse(
      id: body["id"]?.stringValue ?? "", model: body["model"]?.stringValue ?? "",
      content: content, stopReason: stopReason(body["stop_reason"]?.stringValue), usage: usage,
      serverSteps: steps)
  }

  static func failure(_ error: JSONValue?) -> EndpointFailure {
    let message = error?["message"]?.stringValue ?? "The endpoint failed to answer."
    switch error?["type"]?.stringValue {
    case "rate_limit_error"?: return EndpointFailure(kind: .rateLimited, message: message)
    case "overloaded_error"?: return EndpointFailure(kind: .overloaded, message: message)
    case "authentication_error"?: return EndpointFailure(kind: .authentication, message: message)
    case "permission_error"?: return EndpointFailure(kind: .permission, message: message)
    case "not_found_error"?: return EndpointFailure(kind: .notFound, message: message)
    case "invalid_request_error"?:
      return EndpointFailure(
        kind: EndpointFailure.looksLikeContextOverflow(message) ? .contextTooLong : .invalidRequest,
        message: message)
    default: return EndpointFailure(kind: .server, message: message)
    }
  }
}

/// Reads a Messages stream into canonical events, with the endpoint's blocks renumbered densely:
/// the blocks of the tools an agent on the server ran are steps, not blocks.
public struct AnthropicMessagesStreamDecoder: Sendable {
  private var indexes: [Int: Int] = [:]
  private var nextIndex = 0
  private var serverCalls: [Int: (id: String, name: String, input: String)] = [:]
  private var serverCallsByID: [String: (name: String, input: String)] = [:]
  private var serverResults: [Int: (type: String, toolUseID: String, content: String)] = [:]
  private var usage = CanonicalUsage()
  private var stopReason: CanonicalStopReason = .endTurn
  private var stopped = false

  public init() {}

  public mutating func consume(_ event: ServerSentEvent) throws -> [CanonicalStreamEvent] {
    guard let json = try? JSONValue(parsing: event.data) else {
      throw EndpointFailure(
        kind: .malformedResponse, message: "The endpoint sent a stream event that is not JSON.")
    }
    return try consume(json)
  }

  public mutating func consume(_ event: JSONValue) throws -> [CanonicalStreamEvent] {
    let wire = event["index"]?.intValue ?? 0
    switch event["type"]?.stringValue {
    case "message_start":
      let message = event["message"] ?? [:]
      AnthropicMessagesClient.usage(message["usage"], into: &usage)
      return [
        .start(id: message["id"]?.stringValue ?? "", model: message["model"]?.stringValue ?? "")
      ]
    case "content_block_start":
      let block = event["content_block"] ?? [:]
      switch block["type"]?.stringValue {
      case "text":
        return [.textStart(index: take(wire))]
      case "thinking":
        return [.reasoningStart(index: take(wire))]
      case "tool_use":
        return [
          .toolCallStart(
            index: take(wire), id: block["id"]?.stringValue ?? "",
            name: block["name"]?.stringValue ?? "")
        ]
      case "server_tool_use", "mcp_tool_use":
        serverCalls[wire] = (
          block["id"]?.stringValue ?? "", block["name"]?.stringValue ?? "tool", ""
        )
        return []
      case let type? where type.hasSuffix("_tool_result"):
        serverResults[wire] = (
          type, block["tool_use_id"]?.stringValue ?? "", block["content"]?.text() ?? ""
        )
        return []
      default:
        return []
      }
    case "content_block_delta":
      let delta = event["delta"] ?? [:]
      if var call = serverCalls[wire] {
        call.input += delta["partial_json"]?.stringValue ?? ""
        serverCalls[wire] = call
        return []
      }
      guard let index = indexes[wire] else { return [] }
      switch delta["type"]?.stringValue {
      case "text_delta":
        return [.textDelta(index: index, text: delta["text"]?.stringValue ?? "")]
      case "thinking_delta":
        return [.reasoningDelta(index: index, text: delta["thinking"]?.stringValue ?? "")]
      case "signature_delta":
        return [.reasoningSignature(index: index, signature: delta["signature"]?.stringValue ?? "")]
      case "input_json_delta":
        return [
          .toolCallArgumentsDelta(index: index, fragment: delta["partial_json"]?.stringValue ?? "")
        ]
      default:
        return []
      }
    case "content_block_stop":
      if let call = serverCalls.removeValue(forKey: wire) {
        serverCallsByID[call.id] = (call.name, call.input)
        return []
      }
      if let result = serverResults.removeValue(forKey: wire) {
        let call = serverCallsByID.removeValue(forKey: result.toolUseID)
        return [
          .serverStep(
            CanonicalServerStep(
              name: call?.name ?? result.type, input: call?.input, output: result.content))
        ]
      }
      guard let index = indexes.removeValue(forKey: wire) else { return [] }
      return [.blockStop(index: index)]
    case "message_delta":
      AnthropicMessagesClient.usage(event["usage"], into: &usage)
      if let reason = event["delta"]?["stop_reason"]?.stringValue {
        stopReason = AnthropicMessagesClient.stopReason(reason)
      }
      return []
    case "message_stop":
      stopped = true
      return [.usage(usage), .stop(stopReason)]
    case "error":
      throw AnthropicMessagesClient.failure(event["error"])
    default:
      return []
    }
  }

  private mutating func take(_ wire: Int) -> Int {
    let index = nextIndex
    nextIndex += 1
    indexes[wire] = index
    return index
  }

  public mutating func finish() throws -> [CanonicalStreamEvent] {
    guard stopped else {
      throw EndpointFailure(
        kind: .network, message: "The endpoint's answer ended before it was complete.")
    }
    return []
  }
}
