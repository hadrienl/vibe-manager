import Foundation

/// The OpenAI Responses protocol as the gateway speaks it to an endpoint.
///
/// The protocol of an agent on the server (#107 §4): the endpoint runs its own tools — search,
/// files, MCP servers — and reports each as an output item, while calls to the harness's tools come
/// back as `function_call` items for the harness to run. Hosted items become server steps, shown in
/// the conversation and never replayed.
public enum ResponsesClient {
  public static let path = "responses"

  public static func encodeRequest(_ request: CanonicalRequest) -> JSONValue {
    var input: [JSONValue] = []
    for message in request.messages {
      for block in message.content {
        switch (message.role, block) {
        case (.assistant, .text(let text)):
          input.append(
            [
              "type": "message", "role": "assistant",
              "content": [["type": "output_text", "text": .string(text)]],
            ])
        case (_, .text(let text)):
          input.append(
            [
              "type": "message", "role": message.role == .system ? "developer" : "user",
              "content": [["type": "input_text", "text": .string(text)]],
            ])
        case (_, .image(let mediaType, let base64)):
          input.append(
            [
              "type": "message", "role": "user",
              "content": [
                ["type": "input_image", "image_url": .string("data:\(mediaType);base64,\(base64)")]
              ],
            ])
        case (_, .toolCall(let id, let name, let arguments)):
          input.append(
            [
              "type": "function_call", "call_id": .string(id), "name": .string(name),
              "arguments": .string(arguments),
            ])
        case (_, .toolResult(let callID, let content, let isError)):
          var text = content.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
          }.joined()
          if isError, !text.hasPrefix("Error") { text = "Error: " + text }
          input.append(
            ["type": "function_call_output", "call_id": .string(callID), "output": .string(text)])
        case (_, .reasoning):
          continue
        }
      }
    }
    var body: [String: JSONValue] = [
      "model": .string(request.model),
      "input": .array(input),
      "stream": .bool(request.stream),
      // Nothing is kept on the endpoint's side: every request carries the whole conversation.
      "store": false,
    ]
    if let system = request.system { body["instructions"] = .string(system) }
    if !request.tools.isEmpty {
      body["tools"] = .array(
        request.tools.map { tool in
          var fields: [String: JSONValue] = [
            "type": "function", "name": .string(tool.name), "parameters": tool.inputSchema,
          ]
          if let description = tool.description { fields["description"] = .string(description) }
          return .object(fields)
        })
      switch request.toolChoice {
      case .auto: break
      case .none: body["tool_choice"] = "none"
      case .required: body["tool_choice"] = "required"
      case .tool(let name): body["tool_choice"] = ["type": "function", "name": .string(name)]
      }
    }
    if let maxOutputTokens = request.maxOutputTokens {
      body["max_output_tokens"] = .number(Double(maxOutputTokens))
    }
    if let temperature = request.temperature { body["temperature"] = .number(temperature) }
    return .object(body)
  }

  static func usage(_ value: JSONValue?) -> CanonicalUsage? {
    guard let value, value.objectValue != nil else { return nil }
    let cached = value["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0
    return CanonicalUsage(
      inputTokens: max(0, (value["input_tokens"]?.intValue ?? 0) - cached),
      outputTokens: value["output_tokens"]?.intValue ?? 0,
      cacheReadTokens: cached,
      reasoningTokens: value["output_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0)
  }

  /// A hosted tool's item as a server step, or `nil` for the items the harness handles itself.
  static func serverStep(_ item: JSONValue) -> CanonicalServerStep? {
    guard let type = item["type"]?.stringValue, type.hasSuffix("_call"),
      type != "function_call", type != "custom_tool_call"
    else { return nil }
    let name = item["name"]?.stringValue ?? String(type.dropLast("_call".count))
    let input =
      item["arguments"]?.stringValue ?? item["action"].map { $0.text() }
      ?? item["queries"].map { $0.text() }
    let output = item["output"]?.stringValue ?? item["results"].map { $0.text() }
    return CanonicalServerStep(name: name, input: input, output: output)
  }

  public static func decodeResponse(_ body: JSONValue) throws -> CanonicalResponse {
    var decoder = ResponsesStreamDecoder()
    var events = try decoder.consume(["type": "response.completed", "response": body])
    events += try decoder.finish()
    var accumulator = CanonicalResponseAccumulator()
    for event in events { accumulator.consume(event) }
    return accumulator.response
  }
}

/// Reads a Responses stream into canonical events.
public struct ResponsesStreamDecoder: Sendable {
  private var started = false
  private var nextIndex = 0
  /// Output index → canonical index, for the items streamed as blocks.
  private var blocks: [Int: Int] = [:]
  private var streamedArguments: Set<Int> = []
  private var streamedText: Set<Int> = []
  private var hasToolCalls = false
  private var completed = false

  public init() {}

  public mutating func consume(_ event: ServerSentEvent) throws -> [CanonicalStreamEvent] {
    guard var json = try? JSONValue(parsing: event.data) else {
      throw EndpointFailure(
        kind: .malformedResponse, message: "The endpoint sent a stream event that is not JSON.")
    }
    if json["type"] == nil, let name = event.name, case .object(var fields) = json {
      fields["type"] = .string(name)
      json = .object(fields)
    }
    return try consume(json)
  }

  public mutating func consume(_ event: JSONValue) throws -> [CanonicalStreamEvent] {
    var out: [CanonicalStreamEvent] = []
    let type = event["type"]?.stringValue ?? ""
    if !started, type.hasPrefix("response.") {
      started = true
      let response = event["response"]
      out.append(
        .start(
          id: response?["id"]?.stringValue ?? "", model: response?["model"]?.stringValue ?? ""))
    }
    let output = event["output_index"]?.intValue ?? 0
    switch type {
    case "response.output_item.added":
      guard let item = event["item"] else { break }
      out += open(item, output: output)
    case "response.output_text.delta":
      guard let index = blocks[output], let delta = event["delta"]?.stringValue else { break }
      streamedText.insert(output)
      out.append(.textDelta(index: index, text: delta))
    case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
      guard let index = blocks[output], let delta = event["delta"]?.stringValue else { break }
      streamedText.insert(output)
      out.append(.reasoningDelta(index: index, text: delta))
    case "response.function_call_arguments.delta":
      guard let index = blocks[output], let delta = event["delta"]?.stringValue else { break }
      streamedArguments.insert(output)
      out.append(.toolCallArgumentsDelta(index: index, fragment: delta))
    case "response.output_item.done":
      guard let item = event["item"] else { break }
      out += close(item, output: output)
    case "response.completed", "response.incomplete":
      let response = event["response"] ?? [:]
      // A response given whole, not streamed: its items were never opened.
      if blocks.isEmpty, nextIndex == 0 {
        for (offset, item) in (response["output"]?.arrayValue ?? []).enumerated() {
          out += open(item, output: offset)
          out += close(item, output: offset)
        }
      }
      if let usage = ResponsesClient.usage(response["usage"]) { out.append(.usage(usage)) }
      let reason: CanonicalStopReason
      if response["status"]?.stringValue == "incomplete" {
        reason =
          response["incomplete_details"]?["reason"]?.stringValue == "content_filter"
          ? .refusal : .maxTokens
      } else {
        reason = hasToolCalls ? .toolUse : .endTurn
      }
      out.append(.stop(reason))
      completed = true
    case "response.failed":
      let error = event["response"]?["error"]
      throw failure(code: error?["code"]?.stringValue, message: error?["message"]?.stringValue)
    case "error":
      throw failure(
        code: event["code"]?.stringValue ?? event["error"]?["code"]?.stringValue,
        message: event["message"]?.stringValue ?? event["error"]?["message"]?.stringValue)
    default:
      break
    }
    return out
  }

  private func failure(code: String?, message: String?) -> EndpointFailure {
    let message = message ?? "The endpoint failed to answer."
    switch code {
    case "rate_limit_exceeded"?:
      return EndpointFailure(kind: .rateLimited, message: message)
    case "context_length_exceeded"?:
      return EndpointFailure(kind: .contextTooLong, message: message)
    case "invalid_prompt"?, "invalid_request_error"?:
      return EndpointFailure(kind: .invalidRequest, message: message)
    default:
      return EndpointFailure(kind: .server, message: message)
    }
  }

  private mutating func open(_ item: JSONValue, output: Int) -> [CanonicalStreamEvent] {
    guard blocks[output] == nil else { return [] }
    switch item["type"]?.stringValue {
    case "message":
      let index = take(output)
      return [.textStart(index: index)]
    case "reasoning":
      let index = take(output)
      return [.reasoningStart(index: index)]
    case "function_call":
      hasToolCalls = true
      let index = take(output)
      return [
        .toolCallStart(
          index: index, id: item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? "",
          name: item["name"]?.stringValue ?? "")
      ]
    default:
      return []
    }
  }

  private mutating func take(_ output: Int) -> Int {
    let index = nextIndex
    nextIndex += 1
    blocks[output] = index
    return index
  }

  private mutating func close(_ item: JSONValue, output: Int) -> [CanonicalStreamEvent] {
    if let step = ResponsesClient.serverStep(item) { return [.serverStep(step)] }
    guard let index = blocks.removeValue(forKey: output) else { return [] }
    var out: [CanonicalStreamEvent] = []
    switch item["type"]?.stringValue {
    case "message" where !streamedText.contains(output):
      let text = (item["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
        .joined()
      if !text.isEmpty { out.append(.textDelta(index: index, text: text)) }
    case "reasoning" where !streamedText.contains(output):
      let text = (item["summary"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
        .joined(separator: "\n\n")
      if !text.isEmpty { out.append(.reasoningDelta(index: index, text: text)) }
    case "function_call" where !streamedArguments.contains(output):
      out.append(
        .toolCallArgumentsDelta(index: index, fragment: item["arguments"]?.stringValue ?? "{}"))
    default:
      break
    }
    out.append(.blockStop(index: index))
    return out
  }

  public mutating func finish() throws -> [CanonicalStreamEvent] {
    guard completed else {
      throw EndpointFailure(
        kind: .network, message: "The endpoint's answer ended before it was complete.")
    }
    return []
  }
}
