import Foundation

// The protocol-neutral shape every translation goes through (#107).
//
// A harness speaks one protocol, an endpoint another. Rather than write one translation per
// pair, each side is translated to and from these types once: two harness protocols and four
// endpoint protocols make six adapters, not eight translations. Only what an agent loop needs is
// modelled: text, images, tool calls and their results, reasoning, usage and the reason a turn
// stopped. Everything else is dropped on purpose, and said so where it happens.

/// One request of the agent loop: the whole conversation so far, and the tools it may call.
public struct CanonicalRequest: Hashable, Sendable {
  public var model: String
  public var system: String?
  public var messages: [CanonicalMessage]
  public var tools: [CanonicalTool]
  public var toolChoice: CanonicalToolChoice
  public var maxOutputTokens: Int?
  public var temperature: Double?
  public var stream: Bool

  public init(
    model: String,
    system: String? = nil,
    messages: [CanonicalMessage],
    tools: [CanonicalTool] = [],
    toolChoice: CanonicalToolChoice = .auto,
    maxOutputTokens: Int? = nil,
    temperature: Double? = nil,
    stream: Bool = true
  ) {
    self.model = model
    self.system = system
    self.messages = messages
    self.tools = tools
    self.toolChoice = toolChoice
    self.maxOutputTokens = maxOutputTokens
    self.temperature = temperature
    self.stream = stream
  }
}

public struct CanonicalMessage: Hashable, Sendable {
  public enum Role: String, Hashable, Sendable {
    case user
    case assistant
    /// Instructions in the middle of a conversation: Claude Code sends its reminders this way.
    case system
  }

  public var role: Role
  public var content: [CanonicalBlock]

  public init(role: Role, content: [CanonicalBlock]) {
    self.role = role
    self.content = content
  }
}

public enum CanonicalBlock: Hashable, Sendable {
  case text(String)
  case image(mediaType: String, base64: String)
  /// `arguments` is the JSON text of the arguments, as the model wrote it.
  case toolCall(id: String, name: String, arguments: String)
  case toolResult(callID: String, content: [CanonicalResultPart], isError: Bool)
  /// What the model thought, when the endpoint says it. Never replayed to another model with a
  /// signature it did not issue: the signature is only kept to go back where it came from.
  case reasoning(text: String, signature: String?)
}

public enum CanonicalResultPart: Hashable, Sendable {
  case text(String)
  case image(mediaType: String, base64: String)
}

public struct CanonicalTool: Hashable, Sendable {
  public var name: String
  public var description: String?
  /// A JSON Schema object.
  public var inputSchema: JSONValue

  public init(name: String, description: String? = nil, inputSchema: JSONValue) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
  }
}

public enum CanonicalToolChoice: Hashable, Sendable {
  case auto
  case none
  /// Any tool, but one.
  case required
  case tool(String)
}

/// Why the model stopped.
public enum CanonicalStopReason: String, Hashable, Sendable {
  case endTurn
  case toolUse
  case maxTokens
  case stopSequence
  case refusal
}

public struct CanonicalUsage: Hashable, Sendable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var cacheReadTokens: Int
  public var cacheWriteTokens: Int
  public var reasoningTokens: Int

  public init(
    inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0,
    cacheWriteTokens: Int = 0, reasoningTokens: Int = 0
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheReadTokens = cacheReadTokens
    self.cacheWriteTokens = cacheWriteTokens
    self.reasoningTokens = reasoningTokens
  }
}

/// A step an agent on the server ran by itself (#107 §4): shown in the conversation, never sent to
/// the harness as a call to make.
public struct CanonicalServerStep: Hashable, Sendable {
  public var name: String
  public var input: String?
  public var output: String?

  public init(name: String, input: String? = nil, output: String? = nil) {
    self.name = name
    self.input = input
    self.output = output
  }
}

/// What an endpoint's answer is made of, in the order it arrives.
///
/// Blocks are numbered by the endpoint adapter, in order of appearance, whatever the endpoint's
/// own numbering: a Chat Completions stream numbers tool calls apart from text, the Messages
/// protocol numbers everything together. A harness adapter can rely on `index` being dense and
/// increasing, and on every block being started before its deltas and stopped once.
public enum CanonicalStreamEvent: Hashable, Sendable {
  case start(id: String, model: String)
  case textStart(index: Int)
  case textDelta(index: Int, text: String)
  case reasoningStart(index: Int)
  case reasoningDelta(index: Int, text: String)
  case reasoningSignature(index: Int, signature: String)
  case toolCallStart(index: Int, id: String, name: String)
  case toolCallArgumentsDelta(index: Int, fragment: String)
  case blockStop(index: Int)
  case serverStep(CanonicalServerStep)
  case usage(CanonicalUsage)
  case stop(CanonicalStopReason)
}

/// A whole answer, for the endpoints and the harness requests that do not stream.
public struct CanonicalResponse: Hashable, Sendable {
  public var id: String
  public var model: String
  public var content: [CanonicalBlock]
  public var stopReason: CanonicalStopReason
  public var usage: CanonicalUsage?
  public var serverSteps: [CanonicalServerStep]

  public init(
    id: String, model: String, content: [CanonicalBlock], stopReason: CanonicalStopReason,
    usage: CanonicalUsage? = nil, serverSteps: [CanonicalServerStep] = []
  ) {
    self.id = id
    self.model = model
    self.content = content
    self.stopReason = stopReason
    self.usage = usage
    self.serverSteps = serverSteps
  }

  /// The events a stream of this answer would have carried: an endpoint that does not stream is
  /// served to a harness that does.
  public var events: [CanonicalStreamEvent] {
    var events: [CanonicalStreamEvent] = [.start(id: id, model: model)]
    for step in serverSteps { events.append(.serverStep(step)) }
    for (index, block) in content.enumerated() {
      switch block {
      case .text(let text):
        events += [.textStart(index: index), .textDelta(index: index, text: text)]
      case .reasoning(let text, let signature):
        events += [.reasoningStart(index: index), .reasoningDelta(index: index, text: text)]
        if let signature { events.append(.reasoningSignature(index: index, signature: signature)) }
      case .toolCall(let id, let name, let arguments):
        events += [
          .toolCallStart(index: index, id: id, name: name),
          .toolCallArgumentsDelta(index: index, fragment: arguments),
        ]
      case .image, .toolResult:
        continue
      }
      events.append(.blockStop(index: index))
    }
    if let usage { events.append(.usage(usage)) }
    events.append(.stop(stopReason))
    return events
  }
}

/// Folds a stream back into a whole answer, for a harness request that did not ask to stream.
public struct CanonicalResponseAccumulator: Sendable {
  private var id = ""
  private var model = ""
  private var blocks: [Int: CanonicalBlock] = [:]
  private var order: [Int] = []
  private var usage: CanonicalUsage?
  private var stopReason: CanonicalStopReason = .endTurn
  private var serverSteps: [CanonicalServerStep] = []

  public init() {}

  public mutating func consume(_ event: CanonicalStreamEvent) {
    switch event {
    case .start(let id, let model):
      self.id = id
      self.model = model
    case .textStart(let index):
      open(index, .text(""))
    case .textDelta(let index, let text):
      if case .text(let current) = blocks[index] { blocks[index] = .text(current + text) }
    case .reasoningStart(let index):
      open(index, .reasoning(text: "", signature: nil))
    case .reasoningDelta(let index, let text):
      if case .reasoning(let current, let signature) = blocks[index] {
        blocks[index] = .reasoning(text: current + text, signature: signature)
      }
    case .reasoningSignature(let index, let signature):
      if case .reasoning(let text, _) = blocks[index] {
        blocks[index] = .reasoning(text: text, signature: signature)
      }
    case .toolCallStart(let index, let id, let name):
      open(index, .toolCall(id: id, name: name, arguments: ""))
    case .toolCallArgumentsDelta(let index, let fragment):
      if case .toolCall(let id, let name, let arguments) = blocks[index] {
        blocks[index] = .toolCall(id: id, name: name, arguments: arguments + fragment)
      }
    case .blockStop:
      break
    case .serverStep(let step):
      serverSteps.append(step)
    case .usage(let usage):
      self.usage = usage
    case .stop(let reason):
      stopReason = reason
    }
  }

  private mutating func open(_ index: Int, _ block: CanonicalBlock) {
    if blocks[index] == nil { order.append(index) }
    blocks[index] = block
  }

  public var response: CanonicalResponse {
    CanonicalResponse(
      id: id, model: model, content: order.compactMap { blocks[$0] }, stopReason: stopReason,
      usage: usage, serverSteps: serverSteps)
  }
}
