import Foundation

/// One thing a conversation holds, as the conversation view shows it (#38).
///
/// Built from the transcript a CLI writes, never from its terminal. Only what can be shown is
/// kept, and bounded: a transcript line can weigh megabytes — Claude Code writes the whole file an
/// edit touched next to the edit — and none of that is needed to say what happened.
public struct ConversationEntry: Identifiable, Hashable, Sendable {
  /// Stable across readings of the same transcript: a later line updates the entry it names.
  public let id: String
  public var date: Date?
  public var content: Content

  public enum Content: Hashable, Sendable {
    /// What the user typed, as Markdown. `attachments` counts the images that came with it.
    case userPrompt(String, attachments: Int)
    /// What the agent answered, as Markdown.
    case agentText(String)
    /// The agent's reasoning, `nil` when its provider keeps the text to itself.
    case reasoning(String?)
    case tool(ToolCall)
    case notice(ConversationNotice)
  }

  public init(id: String, date: Date? = nil, content: Content) {
    self.id = id
    self.date = date
    self.content = content
  }

  public var toolCall: ToolCall? {
    guard case .tool(let call) = content else { return nil }
    return call
  }

  public var isUserPrompt: Bool {
    guard case .userPrompt = content else { return false }
    return true
  }
}

/// Something that happened to the conversation rather than in it.
public enum ConversationNotice: Hashable, Sendable {
  /// The user stopped the turn.
  case interrupted
  /// The agent summarised its context to go on.
  case compacted
  /// A command of the CLI itself — `/clear`, `/model` — or its output. Shown as it was typed.
  case command(String)
  /// A shell command the user ran from the agent's prompt (`!ls`), with what it printed.
  case shell(command: String, output: String?)
  /// The provider could not answer: the text it wrote about it.
  case error(String)
  /// Something the CLI wrote for the user that is not the agent speaking — a summary written
  /// while they were away, a scheduled task firing.
  case information(String)
  /// Another conversation of the same session starts here: a switch of agent, or a new
  /// conversation of the same one.
  case chapter(providerName: String, date: Date?)
  /// The transcript is older than the shapes this reader knows: only the messages are shown.
  case olderFormat
}

/// One call an agent made to one of its tools.
public struct ToolCall: Hashable, Sendable {
  /// The provider's own identifier of the call, which its result names.
  public let callID: String
  public var kind: ToolKind
  public var state: ToolCallState
  /// What the call was asked, already chosen and shortened for display, in the order shown.
  public var parameters: [ToolParameter]
  public var output: ToolOutput?
  public var changes: [FileDiff]
  public var facts: ToolFacts
  /// The agent's own words about the call, when it gave some — Claude Code's `description` of a
  /// command. Preferred as a title: it says why, where the command says how.
  public var summary: String?
  /// A sub-agent's own transcript, read only when the call is unfolded.
  public var subTranscript: URL?

  public init(
    callID: String,
    kind: ToolKind,
    state: ToolCallState = .running,
    parameters: [ToolParameter] = [],
    output: ToolOutput? = nil,
    changes: [FileDiff] = [],
    facts: ToolFacts = ToolFacts(),
    summary: String? = nil,
    subTranscript: URL? = nil
  ) {
    self.callID = callID
    self.kind = kind
    self.state = state
    self.parameters = parameters
    self.output = output
    self.changes = changes
    self.facts = facts
    self.summary = summary
    self.subTranscript = subTranscript
  }

  public func parameter(_ key: ToolParameter.Key) -> String? {
    parameters.first { $0.key == key }?.value
  }

  /// The image a call produced, when it is one that can be shown: a file that exists, of a type
  /// an image viewer reads. Nothing else a transcript names is ever opened (ADR 0023).
  public var producedImage: URL? {
    guard kind == .image, let path = parameter(.path), path.hasPrefix("/") else { return nil }
    let url = URL(fileURLWithPath: path)
    guard Self.imageExtensions.contains(url.pathExtension.lowercased()),
      FileManager.default.fileExists(atPath: path)
    else { return nil }
    return url
  }

  static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"]
}

/// What a tool does, as far as the view needs to know: its icon, its title, and what it may be
/// grouped with.
public enum ToolKind: Hashable, Sendable {
  case read
  case edit
  case create
  case shell
  case search
  case list
  case webFetch
  case webSearch
  case mcp(server: String, tool: String)
  case subagent
  case todo
  case plan
  case question
  /// An image the agent generated, saved to a file.
  case image
  case other(String)

  /// Calls of the same family, one after the other, are shown as one block.
  public var family: String {
    switch self {
    case .read: return "read"
    case .edit, .create: return "edit"
    case .shell: return "shell"
    case .search, .list: return "search"
    case .webFetch, .webSearch: return "web"
    case .mcp(let server, _): return "mcp:\(server)"
    case .subagent: return "subagent"
    case .todo: return "todo"
    case .plan: return "plan"
    case .question: return "question"
    case .image: return "image"
    case .other(let name): return "other:\(name)"
    }
  }

  /// Whether calls of this kind are ever folded together. A question or a plan is read one by
  /// one, and a to-do list replaces the previous one rather than adding to it.
  public var isGroupable: Bool {
    switch self {
    case .todo, .plan, .question, .subagent, .image: return false
    default: return true
    }
  }

  /// Shown unfolded: what they hold is the message, not a detail.
  public var isShownOpen: Bool {
    switch self {
    case .todo, .plan, .question, .image: return true
    default: return false
    }
  }
}

public enum ToolCallState: Hashable, Sendable {
  case running
  /// Waiting for the user to allow it, in the terminal.
  case awaitingPermission
  case succeeded
  case failed(exitCode: Int32?)
  /// The user, or a rule of the CLI, did not let it run.
  case refused
  /// Stopped by the user while it ran.
  case interrupted

  /// The more serious state wins when calls are grouped: a failure is never hidden behind the
  /// success of its neighbours.
  public var severity: Int {
    switch self {
    case .succeeded: return 0
    case .interrupted: return 1
    case .refused: return 2
    case .running: return 3
    case .awaitingPermission: return 4
    case .failed: return 5
    }
  }

  public var isFinished: Bool {
    switch self {
    case .running, .awaitingPermission: return false
    default: return true
    }
  }
}

public struct ToolParameter: Hashable, Sendable {
  public enum Key: String, Hashable, Sendable {
    case command, path, pattern, query, url, server, tool, arguments, description, prompt
    case workingDirectory, lines, plan, question, todo
  }

  public let key: Key
  public let value: String

  public init(_ key: Key, _ value: String) {
    self.key = key
    self.value = value
  }
}

/// What a call printed, cut to a size a view can hold.
public struct ToolOutput: Hashable, Sendable {
  public static let limit = 32 * 1_024

  public let text: String
  /// How much was left out of the middle, in bytes. Zero when the whole output is here.
  public let omittedByteCount: Int
  /// Printed on the error stream, or reported as an error by the tool.
  public let isError: Bool

  public init(text: String, omittedByteCount: Int = 0, isError: Bool = false) {
    self.text = text
    self.omittedByteCount = omittedByteCount
    self.isError = isError
  }

  /// Keeps the beginning and the end, where a command says what it is doing and how it ended.
  public static func bounded(_ text: String, isError: Bool = false, limit: Int = limit)
    -> ToolOutput
  {
    let bytes = Array(text.utf8)
    guard bytes.count > limit else { return ToolOutput(text: text, isError: isError) }
    let half = limit / 2
    let head = String(decoding: bytes[..<half], as: UTF8.self)
    let tail = String(decoding: bytes[(bytes.count - half)...], as: UTF8.self)
    return ToolOutput(
      text: head + "\n…\n" + tail, omittedByteCount: bytes.count - limit, isError: isError)
  }
}

/// Figures a title is made of, gathered when the call and its result are read.
public struct ToolFacts: Hashable, Sendable {
  public var addedLines: Int?
  public var removedLines: Int?
  public var lineCount: Int?
  public var resultCount: Int?
  public var exitCode: Int32?
  public var duration: Duration?
  public var tests: TestOutcome?

  public init(
    addedLines: Int? = nil,
    removedLines: Int? = nil,
    lineCount: Int? = nil,
    resultCount: Int? = nil,
    exitCode: Int32? = nil,
    duration: Duration? = nil,
    tests: TestOutcome? = nil
  ) {
    self.addedLines = addedLines
    self.removedLines = removedLines
    self.lineCount = lineCount
    self.resultCount = resultCount
    self.exitCode = exitCode
    self.duration = duration
    self.tests = tests
  }
}
