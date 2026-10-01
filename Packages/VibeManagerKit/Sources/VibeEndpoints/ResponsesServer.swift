import Foundation

/// The OpenAI Responses protocol as Codex speaks it to the gateway.
///
/// Codex offers two kinds of tools: functions, with a JSON Schema, and "custom" tools such as
/// `apply_patch`, whose input is free text in a grammar. An endpoint that is not OpenAI's knows
/// only functions, so a custom tool is offered as a function of one string argument, `input`, and a
/// call to it is handed back to Codex as the custom call it expects.
///
/// What is dropped: hosted tools (`web_search`, `local_shell`, `image_generation`), which no other
/// endpoint runs; `reasoning` items coming back, whose encrypted content only OpenAI can read;
/// `include`, `store`, `prompt_cache_key` and `text.verbosity`.
public enum ResponsesServer {
  /// The request, and the names of the tools that must be answered as custom calls.
  public struct Decoded: Sendable {
    public var request: CanonicalRequest
    public var customTools: Set<String>
  }

  public static func decodeRequest(_ body: JSONValue) throws -> Decoded {
    guard let model = body["model"]?.stringValue else {
      throw EndpointProtocolError.missingField("model")
    }
    var customTools = Set<String>()
    var tools: [CanonicalTool] = []
    for tool in body["tools"]?.arrayValue ?? [] {
      switch tool["type"]?.stringValue {
      case "function":
        guard let name = tool["name"]?.stringValue else { continue }
        tools.append(
          CanonicalTool(
            name: name, description: tool["description"]?.stringValue,
            inputSchema: tool["parameters"] ?? ["type": "object", "properties": [:]]))
      case "custom":
        guard let name = tool["name"]?.stringValue else { continue }
        customTools.insert(name)
        tools.append(customTool(name: name, tool: tool))
      default:
        continue
      }
    }
    var messages: [CanonicalMessage] = []
    func add(_ role: CanonicalMessage.Role, _ block: CanonicalBlock) {
      if let last = messages.last, last.role == role {
        messages[messages.count - 1].content.append(block)
      } else {
        messages.append(CanonicalMessage(role: role, content: [block]))
      }
    }
    var input = body["input"]?.arrayValue ?? []
    if let text = body["input"]?.stringValue {
      input = [["type": "message", "role": "user", "content": .string(text)]]
    }
    for item in input {
      switch item["type"]?.stringValue ?? "message" {
      case "message":
        let role: CanonicalMessage.Role
        switch item["role"]?.stringValue {
        case "assistant": role = .assistant
        case "developer", "system": role = .system
        default: role = .user
        }
        for block in content(item["content"]) { add(role, block) }
      case "function_call":
        guard let callID = item["call_id"]?.stringValue, let name = item["name"]?.stringValue else {
          throw EndpointProtocolError.invalidField("function_call")
        }
        add(
          .assistant,
          .toolCall(id: callID, name: name, arguments: item["arguments"]?.stringValue ?? "{}"))
      case "custom_tool_call":
        guard let callID = item["call_id"]?.stringValue, let name = item["name"]?.stringValue else {
          throw EndpointProtocolError.invalidField("custom_tool_call")
        }
        let arguments: JSONValue = ["input": .string(item["input"]?.stringValue ?? "")]
        add(.assistant, .toolCall(id: callID, name: name, arguments: arguments.text()))
      case "function_call_output", "custom_tool_call_output":
        guard let callID = item["call_id"]?.stringValue else {
          throw EndpointProtocolError.invalidField("call_id")
        }
        add(.user, .toolResult(callID: callID, content: output(item["output"]), isError: false))
      default:
        // `reasoning` coming back, hosted tool calls: nothing another endpoint could use.
        continue
      }
    }
    let request = CanonicalRequest(
      model: model,
      system: body["instructions"]?.stringValue,
      messages: messages,
      tools: tools,
      toolChoice: toolChoice(body["tool_choice"]),
      maxOutputTokens: body["max_output_tokens"]?.intValue,
      temperature: body["temperature"]?.numberValue,
      stream: body["stream"]?.boolValue ?? false)
    return Decoded(request: request, customTools: customTools)
  }

  private static func customTool(name: String, tool: JSONValue) -> CanonicalTool {
    var description = tool["description"]?.stringValue ?? ""
    if let definition = tool["format"]?["definition"]?.stringValue {
      description += "\n\nThe `input` argument must follow this grammar:\n" + definition
    }
    return CanonicalTool(
      name: name, description: description,
      inputSchema: [
        "type": "object",
        "properties": [
          "input": ["type": "string", "description": "The raw input of the tool, as plain text."]
        ],
        "required": ["input"],
      ])
  }

  private static func toolChoice(_ value: JSONValue?) -> CanonicalToolChoice {
    switch value {
    case .string("none"): return .none
    case .string("required"): return .required
    case .object:
      return value?["name"]?.stringValue.map(CanonicalToolChoice.tool) ?? .auto
    default: return .auto
    }
  }

  private static func content(_ value: JSONValue?) -> [CanonicalBlock] {
    switch value {
    case .string(let text):
      return [.text(text)]
    case .array(let parts):
      return parts.compactMap { part in
        switch part["type"]?.stringValue {
        case "input_text", "output_text", "text":
          return .text(part["text"]?.stringValue ?? "")
        case "input_image":
          guard let url = part["image_url"]?.stringValue, let image = dataURL(url) else {
            return nil
          }
          return .image(mediaType: image.mediaType, base64: image.base64)
        default:
          return nil
        }
      }
    default:
      return []
    }
  }

  private static func output(_ value: JSONValue?) -> [CanonicalResultPart] {
    switch value {
    case .string(let text):
      return [.text(text)]
    case .array(let parts):
      return parts.compactMap { part in
        switch part["type"]?.stringValue {
        case "input_text", "output_text", "text":
          return .text(part["text"]?.stringValue ?? "")
        case "input_image":
          return part["image_url"]?.stringValue.flatMap(dataURL).map {
            .image(mediaType: $0.mediaType, base64: $0.base64)
          }
        default:
          return nil
        }
      }
    default:
      return []
    }
  }

  static func dataURL(_ url: String) -> (mediaType: String, base64: String)? {
    guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ","),
      url[..<comma].hasSuffix(";base64")
    else { return nil }
    let mediaType = url[url.index(url.startIndex, offsetBy: 5)..<comma].dropLast(";base64".count)
    return (String(mediaType), String(url[url.index(after: comma)...]))
  }

  // MARK: - Answers

  static func usage(_ usage: CanonicalUsage?) -> JSONValue {
    let usage = usage ?? CanonicalUsage()
    let input = usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens
    return [
      "input_tokens": .number(Double(input)),
      "input_tokens_details": ["cached_tokens": .number(Double(usage.cacheReadTokens))],
      "output_tokens": .number(Double(usage.outputTokens)),
      "output_tokens_details": ["reasoning_tokens": .number(Double(usage.reasoningTokens))],
      "total_tokens": .number(Double(input + usage.outputTokens)),
    ]
  }

  /// The body Codex reads for an error before any byte of a stream.
  public static func errorBody(_ failure: EndpointFailure) -> JSONValue {
    let code: String
    switch failure.kind {
    case .rateLimited: code = "rate_limit_exceeded"
    case .contextTooLong: code = "context_length_exceeded"
    case .authentication: code = "invalid_api_key"
    default: code = failure.kind.rawValue
    }
    return [
      "error": ["message": .string(failure.message), "type": .string(code), "code": .string(code)]
    ]
  }

  /// Codex retries 429 and 5xx by itself, and gives up on the rest.
  public static func status(for failure: EndpointFailure) -> Int {
    switch failure.kind {
    case .authentication: return 401
    case .permission: return 403
    case .notFound: return 404
    case .rateLimited: return 429
    case .invalidRequest, .contextTooLong: return 400
    case .overloaded, .network, .timeout, .malformedResponse: return 503
    case .server: return 500
    }
  }
}

/// Writes canonical events as the Responses stream Codex reads.
public struct ResponsesStreamEncoder: Sendable {
  private enum Item: Sendable {
    case message(id: String, text: String)
    case reasoning(id: String, text: String)
    case functionCall(id: String, callID: String, name: String, arguments: String)
  }

  private let responseID: String
  private var model: String
  private let customTools: Set<String>
  private var started = false
  private var sequence = 0
  /// Canonical block index → output index and item.
  private var items: [Int: (output: Int, item: Item)] = [:]
  private var done: [JSONValue] = []
  private var nextOutput = 0
  private var usage: CanonicalUsage?
  private var stopReason: CanonicalStopReason = .endTurn

  public init(id: String, model: String, customTools: Set<String>) {
    responseID = id
    self.model = model
    self.customTools = customTools
  }

  public mutating func encode(_ event: CanonicalStreamEvent) -> [ServerSentEvent] {
    var out: [ServerSentEvent] = []
    if !started { out += start() }
    switch event {
    case .start:
      break
    case .textStart(let index):
      let id = "msg_\(index)_" + responseID.suffix(8)
      out += open(index, .message(id: id, text: ""))
      out.append(
        emit(
          "response.content_part.added",
          [
            "item_id": .string(id), "output_index": .number(Double(nextOutput - 1)),
            "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []],
          ]))
    case .textDelta(let index, let text):
      guard case .message(let id, let current)? = items[index]?.item,
        let output = items[index]?.output
      else { break }
      items[index] = (output, .message(id: id, text: current + text))
      out.append(
        emit(
          "response.output_text.delta",
          [
            "item_id": .string(id), "output_index": .number(Double(output)), "content_index": 0,
            "delta": .string(text),
          ]))
    case .reasoningStart(let index):
      out += open(index, .reasoning(id: "rs_\(index)_" + responseID.suffix(8), text: ""))
    case .reasoningDelta(let index, let text):
      guard case .reasoning(let id, let current)? = items[index]?.item,
        let output = items[index]?.output
      else { break }
      items[index] = (output, .reasoning(id: id, text: current + text))
      out.append(
        emit(
          "response.reasoning_summary_text.delta",
          [
            "item_id": .string(id), "output_index": .number(Double(output)), "summary_index": 0,
            "delta": .string(text),
          ]))
    case .reasoningSignature:
      break
    case .toolCallStart(let index, let callID, let name):
      out += open(
        index,
        .functionCall(
          id: "fc_\(index)_" + responseID.suffix(8), callID: callID, name: name, arguments: ""))
    case .toolCallArgumentsDelta(let index, let fragment):
      guard case .functionCall(let id, let callID, let name, let arguments)? = items[index]?.item,
        let output = items[index]?.output
      else { break }
      items[index] = (
        output, .functionCall(id: id, callID: callID, name: name, arguments: arguments + fragment)
      )
      if !customTools.contains(name) {
        out.append(
          emit(
            "response.function_call_arguments.delta",
            [
              "item_id": .string(id), "output_index": .number(Double(output)),
              "delta": .string(fragment),
            ]))
      }
    case .blockStop(let index):
      out += close(index)
    case .serverStep:
      break
    case .usage(let usage):
      self.usage = usage
    case .stop(let reason):
      stopReason = reason
    }
    return out
  }

  public mutating func finish() -> [ServerSentEvent] {
    var out: [ServerSentEvent] = []
    if !started { out += start() }
    for index in items.keys.sorted() { out += close(index) }
    let incomplete = stopReason == .maxTokens
    var response = responseObject(status: incomplete ? "incomplete" : "completed")
    if incomplete, case .object(var fields) = response {
      fields["incomplete_details"] = ["reason": "max_output_tokens"]
      response = .object(fields)
    }
    out.append(
      emit(incomplete ? "response.incomplete" : "response.completed", ["response": response]))
    return out
  }

  /// An error after part of the answer went out. Codex retries a stream that fails this way.
  public mutating func fail(_ failure: EndpointFailure) -> [ServerSentEvent] {
    var out: [ServerSentEvent] = []
    if !started { out += start() }
    var response = responseObject(status: "failed")
    if case .object(var fields) = response {
      let body = ResponsesServer.errorBody(failure)
      fields["error"] = [
        "code": body["error"]?["code"] ?? "server_error", "message": .string(failure.message),
      ]
      response = .object(fields)
    }
    out.append(emit("response.failed", ["response": response]))
    return out
  }

  /// The whole answer, for a request that did not stream.
  public mutating func response(_ answer: CanonicalResponse) -> JSONValue {
    for event in answer.events { _ = encode(event) }
    for index in items.keys.sorted() { _ = close(index) }
    stopReason = answer.stopReason
    usage = answer.usage
    return responseObject(status: answer.stopReason == .maxTokens ? "incomplete" : "completed")
  }

  private mutating func start() -> [ServerSentEvent] {
    started = true
    let response = responseObject(status: "in_progress")
    return [
      emit("response.created", ["response": response]),
      emit("response.in_progress", ["response": response]),
    ]
  }

  private func responseObject(status: String) -> JSONValue {
    var fields: [String: JSONValue] = [
      "id": .string(responseID), "object": "response", "status": .string(status),
      "model": .string(model), "output": .array(done),
    ]
    if status != "in_progress" { fields["usage"] = ResponsesServer.usage(usage) }
    return .object(fields)
  }

  private mutating func open(_ index: Int, _ item: Item) -> [ServerSentEvent] {
    let output = nextOutput
    nextOutput += 1
    items[index] = (output, item)
    return [
      emit(
        "response.output_item.added",
        ["output_index": .number(Double(output)), "item": json(item, status: "in_progress")])
    ]
  }

  private mutating func close(_ index: Int) -> [ServerSentEvent] {
    guard let (output, item) = items.removeValue(forKey: index) else { return [] }
    var out: [ServerSentEvent] = []
    switch item {
    case .message(let id, let text):
      out.append(
        emit(
          "response.output_text.done",
          [
            "item_id": .string(id), "output_index": .number(Double(output)), "content_index": 0,
            "text": .string(text),
          ]))
      out.append(
        emit(
          "response.content_part.done",
          [
            "item_id": .string(id), "output_index": .number(Double(output)), "content_index": 0,
            "part": ["type": "output_text", "text": .string(text), "annotations": []],
          ]))
    case .functionCall(let id, _, let name, let arguments) where !customTools.contains(name):
      out.append(
        emit(
          "response.function_call_arguments.done",
          [
            "item_id": .string(id), "output_index": .number(Double(output)),
            "arguments": .string(arguments),
          ]))
    default:
      break
    }
    let finished = json(item, status: "completed")
    done.append(finished)
    out.append(
      emit(
        "response.output_item.done", ["output_index": .number(Double(output)), "item": finished]))
    return out
  }

  private func json(_ item: Item, status: String) -> JSONValue {
    switch item {
    case .message(let id, let text):
      return [
        "type": "message", "id": .string(id), "role": "assistant", "status": .string(status),
        "content": status == "completed"
          ? [["type": "output_text", "text": .string(text), "annotations": []]] : [],
      ]
    case .reasoning(let id, let text):
      return [
        "type": "reasoning", "id": .string(id),
        "summary": text.isEmpty ? [] : [["type": "summary_text", "text": .string(text)]],
      ]
    case .functionCall(let id, let callID, let name, let arguments):
      if customTools.contains(name) {
        let input =
          (try? JSONValue(parsing: arguments))?["input"]?.stringValue ?? arguments
        return [
          "type": "custom_tool_call", "id": .string(id), "call_id": .string(callID),
          "name": .string(name), "input": .string(input), "status": .string(status),
        ]
      }
      return [
        "type": "function_call", "id": .string(id), "call_id": .string(callID),
        "name": .string(name), "arguments": .string(arguments), "status": .string(status),
      ]
    }
  }

  private mutating func emit(_ type: String, _ fields: [String: JSONValue]) -> ServerSentEvent {
    var fields = fields
    fields["type"] = .string(type)
    fields["sequence_number"] = .number(Double(sequence))
    sequence += 1
    return ServerSentEvent(name: type, data: JSONValue.object(fields).text())
  }
}
