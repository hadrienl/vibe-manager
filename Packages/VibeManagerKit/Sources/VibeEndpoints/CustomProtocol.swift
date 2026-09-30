import Foundation

/// An endpoint that follows no standard, described rather than programmed (#107 §3).
///
/// A JSON document says how to build a request from the conversation and how to read the answer.
/// On purpose it is not a language: paths into JSON, a comparison, and a handful of named values to
/// put in a request. A need it cannot express is met by adding a named value here, tested, rather
/// than by letting a settings field run code.
///
/// ```json
/// {
///   "schema": 1,
///   "request": {
///     "path": "agents/{{model}}/chat",
///     "body": {"input": "{{lastUserText}}", "history": "{{messages:openai}}", "stream": true}
///   },
///   "stream": {"format": "sse"},
///   "events": [
///     {"when": {"path": "type", "equals": "delta"}, "text": "content"},
///     {"when": {"path": "type", "equals": "tool"}, "toolCall": {"id": "id", "name": "name", "arguments": "args"}},
///     {"when": {"path": "type", "equals": "step"}, "serverStep": {"name": "tool", "input": "input", "output": "result"}},
///     {"when": {"path": "type", "equals": "usage"}, "usage": {"input": "prompt_tokens", "output": "completion_tokens"}},
///     {"when": {"path": "type", "equals": "error"}, "error": "message"},
///     {"when": {"path": "type", "equals": "done"}, "stop": true}
///   ],
///   "models": {"path": "agents", "list": "items", "id": "slug", "name": "title"}
/// }
/// ```
public struct CustomProtocolDocument: Hashable, Sendable {
  public struct Request: Hashable, Sendable {
    public var method: String
    public var path: String
    public var body: JSONValue
  }

  public enum StreamFormat: String, Hashable, Sendable {
    /// Server-Sent Events, one JSON object per `data:`.
    case sse
    /// One JSON object per line.
    case ndjson
    /// One JSON object, the whole answer.
    case none
  }

  public struct Condition: Hashable, Sendable {
    public var path: JSONPath
    public var equals: JSONValue?

    func matches(_ value: JSONValue) -> Bool {
      guard let found = path.value(in: value) else { return false }
      guard let equals else { return !found.isNull }
      return found == equals
    }
  }

  public enum Action: Hashable, Sendable {
    case text(JSONPath)
    case reasoning(JSONPath)
    case toolCall(id: JSONPath?, name: JSONPath, arguments: JSONPath?)
    case serverStep(name: JSONPath, input: JSONPath?, output: JSONPath?)
    case usage(input: JSONPath?, output: JSONPath?)
    case error(JSONPath)
    case stop
  }

  public struct Rule: Hashable, Sendable {
    public var when: Condition?
    public var actions: [Action]
  }

  public struct Models: Hashable, Sendable {
    public var path: String
    public var list: JSONPath
    public var id: JSONPath
    public var name: JSONPath?
  }

  public var request: Request
  public var stream: StreamFormat
  public var rules: [Rule]
  public var models: Models?

  public static let schema = 1
}

/// A path into a JSON value: keys and indexes separated by dots, `choices.0.delta.content`.
public struct JSONPath: Hashable, Sendable, CustomStringConvertible {
  public let components: [String]

  public init(_ text: String) {
    components = text.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
  }

  public var description: String { components.joined(separator: ".") }

  public func value(in root: JSONValue) -> JSONValue? {
    var current = root
    for component in components {
      if let index = Int(component), case .array(let items) = current {
        guard items.indices.contains(index) else { return nil }
        current = items[index]
      } else if let next = current[component] {
        current = next
      } else {
        return nil
      }
    }
    return current
  }

  func string(in root: JSONValue) -> String? {
    guard let value = value(in: root) else { return nil }
    switch value {
    case .string(let text): return text
    case .null: return nil
    case .number, .bool, .array, .object: return value.text()
    }
  }
}

/// Where a document does not say what it should, with where: `events[2].toolCall.name`.
public struct CustomProtocolError: Error, Hashable, Sendable, CustomStringConvertible {
  public var location: String
  public var problem: String

  public var description: String { "\(location): \(problem)" }
}

extension CustomProtocolDocument {
  /// Reads and checks a document, naming the first place that is wrong.
  public init(parsing text: String) throws {
    let root: JSONValue
    do {
      root = try JSONValue(parsing: text)
    } catch {
      throw CustomProtocolError(location: "document", problem: "is not JSON")
    }
    guard case .object = root else {
      throw CustomProtocolError(location: "document", problem: "must be a JSON object")
    }
    if let schema = root["schema"]?.intValue, schema > Self.schema {
      throw CustomProtocolError(location: "schema", problem: "is newer than this version reads")
    }
    guard let request = root["request"], case .object = request else {
      throw CustomProtocolError(location: "request", problem: "is missing")
    }
    guard let path = request["path"]?.stringValue, !path.isEmpty else {
      throw CustomProtocolError(location: "request.path", problem: "is missing")
    }
    self.request = Request(
      method: request["method"]?.stringValue?.uppercased() ?? "POST", path: path,
      body: request["body"] ?? [:])
    let format = root["stream"]?["format"]?.stringValue ?? "sse"
    guard let stream = StreamFormat(rawValue: format) else {
      throw CustomProtocolError(location: "stream.format", problem: "must be sse, ndjson or none")
    }
    self.stream = stream
    guard let events = root["events"]?.arrayValue, !events.isEmpty else {
      throw CustomProtocolError(location: "events", problem: "must list at least one rule")
    }
    rules = try events.enumerated().map { index, event in
      try Self.rule(event, at: "events[\(index)]")
    }
    guard rules.contains(where: { $0.actions.contains(where: Self.isText) }) else {
      throw CustomProtocolError(location: "events", problem: "no rule reads the answer's text")
    }
    if let models = root["models"], case .object = models {
      guard let modelsPath = models["path"]?.stringValue, let id = models["id"]?.stringValue else {
        throw CustomProtocolError(location: "models", problem: "needs a path and an id")
      }
      self.models = Models(
        path: modelsPath, list: JSONPath(models["list"]?.stringValue ?? ""), id: JSONPath(id),
        name: models["name"]?.stringValue.map(JSONPath.init))
    } else {
      models = nil
    }
  }

  private static func isText(_ action: Action) -> Bool {
    if case .text = action { return true }
    return false
  }

  private static func rule(_ event: JSONValue, at location: String) throws -> Rule {
    var condition: Condition?
    if let when = event["when"] {
      guard let path = when["path"]?.stringValue else {
        throw CustomProtocolError(location: "\(location).when.path", problem: "is missing")
      }
      condition = Condition(path: JSONPath(path), equals: when["equals"])
    }
    func path(_ key: String, in value: JSONValue?, required: Bool, at place: String) throws
      -> JSONPath?
    {
      guard let text = value?[key]?.stringValue, !text.isEmpty else {
        if required {
          throw CustomProtocolError(location: "\(place).\(key)", problem: "is missing")
        }
        return nil
      }
      return JSONPath(text)
    }
    var actions: [Action] = []
    if let text = event["text"]?.stringValue { actions.append(.text(JSONPath(text))) }
    if let text = event["reasoning"]?.stringValue { actions.append(.reasoning(JSONPath(text))) }
    if let call = event["toolCall"] {
      let place = "\(location).toolCall"
      actions.append(
        .toolCall(
          id: try path("id", in: call, required: false, at: place),
          name: try path("name", in: call, required: true, at: place) ?? JSONPath(""),
          arguments: try path("arguments", in: call, required: false, at: place)))
    }
    if let step = event["serverStep"] {
      let place = "\(location).serverStep"
      actions.append(
        .serverStep(
          name: try path("name", in: step, required: true, at: place) ?? JSONPath(""),
          input: try path("input", in: step, required: false, at: place),
          output: try path("output", in: step, required: false, at: place)))
    }
    if let usage = event["usage"] {
      let place = "\(location).usage"
      actions.append(
        .usage(
          input: try path("input", in: usage, required: false, at: place),
          output: try path("output", in: usage, required: false, at: place)))
    }
    if let error = event["error"]?.stringValue { actions.append(.error(JSONPath(error))) }
    if event["stop"]?.boolValue == true { actions.append(.stop) }
    guard !actions.isEmpty else {
      throw CustomProtocolError(location: location, problem: "does nothing")
    }
    return Rule(when: condition, actions: actions)
  }
}

// MARK: - Requests

extension CustomProtocolDocument {
  /// The request's path, with the model in it when the document asks.
  public func operationPath(model: String) -> String {
    request.path.replacingOccurrences(
      of: "{{model}}",
      with: model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model)
  }

  /// The request's body: the document's template with the conversation put in it.
  public func body(for canonical: CanonicalRequest) -> JSONValue {
    Self.fill(request.body, with: Self.values(for: canonical))
  }

  /// The named values a template may use.
  static func values(for request: CanonicalRequest) -> [String: JSONValue] {
    let chat = ChatCompletionsClient.encodeRequest(request)
    let anthropic = AnthropicMessagesClient.encodeRequest(request, defaultMaximumTokens: nil)
    var lastUser = ""
    for message in request.messages.reversed() where message.role == .user {
      let texts = message.content.compactMap { block -> String? in
        if case .text(let text) = block { return text }
        return nil
      }
      if !texts.isEmpty {
        lastUser = texts.joined(separator: "\n\n")
        break
      }
    }
    var transcript: [String] = []
    for message in request.messages {
      for block in message.content {
        switch block {
        case .text(let text): transcript.append("\(message.role.rawValue): \(text)")
        case .toolCall(_, let name, let arguments):
          transcript.append("assistant called \(name) with \(arguments)")
        case .toolResult(_, let parts, _):
          let text = parts.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
          }.joined()
          transcript.append("tool result: \(text)")
        case .image, .reasoning: continue
        }
      }
    }
    return [
      "model": .string(request.model),
      "system": request.system.map(JSONValue.string) ?? .null,
      "stream": .bool(request.stream),
      "maxTokens": request.maxOutputTokens.map { .number(Double($0)) } ?? .null,
      "lastUserText": .string(lastUser),
      "transcript": .string(transcript.joined(separator: "\n\n")),
      "messages:openai": chat["messages"] ?? [],
      "messages:anthropic": anthropic["messages"] ?? [],
      "tools:openai": chat["tools"] ?? [],
      "tools:anthropic": anthropic["tools"] ?? [],
      "uuid": .string(UUID().uuidString.lowercased()),
    ]
  }

  /// A string that is exactly `{{name}}` becomes the value, whatever its type; a name inside a
  /// longer string is replaced by the value's text.
  static func fill(_ template: JSONValue, with values: [String: JSONValue]) -> JSONValue {
    switch template {
    case .string(let text):
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}"), trimmed.count > 4 {
        let name = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
        if let value = values[name], !text.dropFirst(2).dropLast(2).contains("{{") {
          return value
        }
      }
      var result = text
      for (name, value) in values where result.contains("{{\(name)}}") {
        let replacement = value.stringValue ?? (value.isNull ? "" : value.text())
        result = result.replacingOccurrences(of: "{{\(name)}}", with: replacement)
      }
      return .string(result)
    case .array(let items):
      return .array(items.map { fill($0, with: values) })
    case .object(let fields):
      return .object(fields.mapValues { fill($0, with: values) })
    case .null, .bool, .number:
      return template
    }
  }
}

// MARK: - Answers

/// Reads an answer by the document's rules into canonical events.
///
/// Every event is matched against every rule, in order, and every rule that matches acts: one
/// event of an endpoint may carry text and usage together. Text and reasoning stream; tool calls
/// are handed over at the end, whole, as for Chat Completions.
public struct CustomProtocolDecoder: Sendable {
  private let document: CustomProtocolDocument
  private var started = false
  private var nextIndex = 0
  private var open: (index: Int, isText: Bool)?
  private var calls: [(id: String, name: String, arguments: String)] = []
  private var usage: CanonicalUsage?
  private var stopped = false

  public init(document: CustomProtocolDocument) {
    self.document = document
  }

  public mutating func consume(_ event: ServerSentEvent) throws -> [CanonicalStreamEvent] {
    let data = event.data.trimmingCharacters(in: .whitespaces)
    guard !data.isEmpty, data != "[DONE]" else { return [] }
    guard let json = try? JSONValue(parsing: data) else {
      throw EndpointFailure(
        kind: .malformedResponse, message: "The endpoint sent a stream event that is not JSON.")
    }
    return try consume(json)
  }

  /// A line of an NDJSON stream, or a line that is not SSE.
  public mutating func consumeStray(_ line: String) -> [CanonicalStreamEvent] {
    guard let json = try? JSONValue(parsing: line) else { return [] }
    return (try? consume(json)) ?? []
  }

  public mutating func consume(_ event: JSONValue) throws -> [CanonicalStreamEvent] {
    var out: [CanonicalStreamEvent] = []
    if !started {
      started = true
      out.append(.start(id: "", model: ""))
    }
    for rule in document.rules where rule.when?.matches(event) ?? true {
      for action in rule.actions {
        switch action {
        case .text(let path):
          if let text = path.string(in: event), !text.isEmpty { out += append(text, isText: true) }
        case .reasoning(let path):
          if let text = path.string(in: event), !text.isEmpty { out += append(text, isText: false) }
        case .toolCall(let id, let name, let arguments):
          guard let name = name.string(in: event), !name.isEmpty else { continue }
          calls.append(
            (
              id: id.flatMap { $0.string(in: event) } ?? "call_\(calls.count + 1)", name: name,
              arguments: arguments.flatMap { $0.string(in: event) } ?? "{}"
            ))
        case .serverStep(let name, let input, let output):
          guard let name = name.string(in: event) else { continue }
          out.append(
            .serverStep(
              CanonicalServerStep(
                name: name, input: input.flatMap { $0.string(in: event) },
                output: output.flatMap { $0.string(in: event) })))
        case .usage(let input, let output):
          var usage = self.usage ?? CanonicalUsage()
          if let value = input?.value(in: event)?.intValue { usage.inputTokens = value }
          if let value = output?.value(in: event)?.intValue { usage.outputTokens = value }
          self.usage = usage
        case .error(let path):
          if let message = path.string(in: event) {
            throw EndpointFailure(kind: .server, message: message)
          }
        case .stop:
          stopped = true
        }
      }
    }
    return out
  }

  private mutating func append(_ text: String, isText: Bool) -> [CanonicalStreamEvent] {
    var out: [CanonicalStreamEvent] = []
    if open?.isText != isText {
      if let open { out.append(.blockStop(index: open.index)) }
      let index = nextIndex
      nextIndex += 1
      open = (index, isText)
      out.append(isText ? .textStart(index: index) : .reasoningStart(index: index))
    }
    guard let index = open?.index else { return out }
    out.append(
      isText ? .textDelta(index: index, text: text) : .reasoningDelta(index: index, text: text))
    return out
  }

  /// Whether a `stop` rule matched: the answer is over, whatever the stream does next.
  public var hasEnded: Bool { stopped }

  public mutating func finish() throws -> [CanonicalStreamEvent] {
    guard started else {
      throw EndpointFailure(kind: .malformedResponse, message: "The endpoint sent no answer.")
    }
    // A document that says how an answer ends, and a stream closed before it: cut short.
    if !stopped, document.rules.contains(where: { $0.actions.contains(.stop) }) {
      throw EndpointFailure(
        kind: .network, message: "The endpoint's answer ended before it was complete.")
    }
    var out: [CanonicalStreamEvent] = []
    if let open { out.append(.blockStop(index: open.index)) }
    open = nil
    for call in calls {
      let index = nextIndex
      nextIndex += 1
      out.append(.toolCallStart(index: index, id: call.id, name: call.name))
      out.append(
        .toolCallArgumentsDelta(
          index: index, fragment: try ChatCompletionsClient.validArguments(call.arguments)))
      out.append(.blockStop(index: index))
    }
    if let usage { out.append(.usage(usage)) }
    out.append(.stop(calls.isEmpty ? .endTurn : .toolUse))
    return out
  }
}
