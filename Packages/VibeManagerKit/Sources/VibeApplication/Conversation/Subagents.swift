import Foundation

/// A sub-agent one of the agent's calls started (#180): what it was, how it went, what it answered,
/// and — once its own transcript is read — what it did.
///
/// Its state is the state of the call that started it, so that severity, grouping and the banner
/// keep working. Everything here comes from the main transcript but `activity`: a sub-agent that
/// is done is shown without opening its file (ADR 0034).
public struct SubagentRun: Hashable, Sendable {
  public enum Mode: Hashable, Sendable {
    /// The call waits for the sub-agent and returns what it answered.
    case foreground
    /// The call returns at once; the sub-agent's end is notified later.
    case background
  }

  /// The CLI's identifier of the sub-agent: Claude Code's `agentId`, Codex's thread. Known when
  /// the call returns — at once for one in the background.
  public var agentID: String?
  /// What kind of sub-agent: `Explore`, `general-purpose`, a skill's name, Codex's agent path.
  public var type: String?
  public var mode: Mode
  /// What it answered, as Markdown, bounded like any output.
  public var result: String?
  /// Why it failed, when it did: an error of its provider, in its own words.
  public var failure: String?
  public var usage: SubagentUsage?
  /// When it started, for the time it has been running.
  public var startedAt: Date?
  /// How many tasks it was given: Codex hands the same sub-agent several.
  public var taskCount: Int
  /// Its own transcript, once found.
  public var transcript: URL?
  public var activity: SubagentActivity
  /// 1 for a sub-agent of the agent itself, 2 for one of its sub-agents, and so on.
  public var depth: Int

  public init(
    agentID: String? = nil,
    type: String? = nil,
    mode: Mode = .foreground,
    result: String? = nil,
    failure: String? = nil,
    usage: SubagentUsage? = nil,
    startedAt: Date? = nil,
    taskCount: Int = 1,
    transcript: URL? = nil,
    activity: SubagentActivity = .unread,
    depth: Int = 1
  ) {
    self.agentID = agentID
    self.type = type
    self.mode = mode
    self.result = result
    self.failure = failure
    self.usage = usage
    self.startedAt = startedAt
    self.taskCount = taskCount
    self.transcript = transcript
    self.activity = activity
    self.depth = depth
  }

  /// Past this depth, a sub-agent shows its header and its answer, not its activity.
  public static let maximumShownDepth = 3

  /// Its conversation, when it was read.
  public var activityEntries: [ConversationEntry]? {
    guard case .read(let entries) = activity else { return nil }
    return entries
  }
}

/// What the CLI counted of a sub-agent's work when it ended.
public struct SubagentUsage: Hashable, Sendable {
  public var toolUses: Int?
  public var duration: Duration?
  public var tokens: Int?

  public init(toolUses: Int? = nil, duration: Duration? = nil, tokens: Int? = nil) {
    self.toolUses = toolUses
    self.duration = duration
    self.tokens = tokens
  }
}

/// A sub-agent's own conversation, read only while it runs or once the user unfolds it.
public enum SubagentActivity: Hashable, Sendable {
  /// Never opened: what a sub-agent that is done normally is.
  case unread
  /// Asked for, not read yet: its transcript is being found or read.
  case loading
  case read([ConversationEntry])
  /// Done, and no transcript of its own was found: a call the CLI refused, a folder cleaned up.
  case notFound
}

/// What a sub-agent's activity amounts to, for its folded block.
public struct SubagentActivitySummary: Hashable, Sendable {
  public var toolCount: Int
  /// Files it created or edited.
  public var editedFileCount: Int
  /// Its last calls, most recent last: what it is doing, while it runs.
  public var lastActions: [ToolCall]

  public init(entries: [ConversationEntry], lastActionCount: Int = 3) {
    let calls = entries.compactMap(\.toolCall)
    toolCount = calls.count
    var files: Set<String> = []
    for call in calls where call.kind == .edit || call.kind == .create {
      if let path = call.parameter(.path) { files.insert(path) }
      files.formUnion(call.changes.map(\.path))
    }
    editedFileCount = files.count
    lastActions = Array(calls.suffix(lastActionCount))
  }
}

/// A sub-agent's transcript as its CLI lists it, before it is opened.
public struct SubagentTranscriptInfo: Hashable, Sendable {
  public let agentID: String
  /// The call that started it, when the CLI wrote it down: Claude Code's `meta.json` does from
  /// the moment the sub-agent starts, before its first line.
  public let toolUseID: String?
  public let file: URL
  public let createdAt: Date?

  public init(agentID: String, toolUseID: String? = nil, file: URL, createdAt: Date? = nil) {
    self.agentID = agentID
    self.toolUseID = toolUseID
    self.file = file
    self.createdAt = createdAt
  }
}

/// Ties each sub-agent call to its own transcript (#180, ADR 0034).
///
/// By identifier, never by guessing silently: the call named by the transcript's own record first,
/// then the sub-agent's identifier once the call returned it, and only for transcripts that name no
/// call, a prompt that is the same word for word. Without any of these, no link: the next look
/// may find one. Never "the newest file".
public enum SubagentLinker {
  public struct Call: Hashable, Sendable {
    public let callID: String
    public let agentID: String?
    public let prompt: String?
    public let date: Date?

    public init(callID: String, agentID: String? = nil, prompt: String? = nil, date: Date? = nil) {
      self.callID = callID
      self.agentID = agentID
      self.prompt = prompt
      self.date = date
    }
  }

  /// A transcript created this long before its call is still taken for it: the CLI and the
  /// transcript's clock are not the same.
  static let tolerance: TimeInterval = 1

  /// The transcript of each call that has one, by call identifier.
  ///
  /// - Parameters:
  ///   - taken: transcripts already tied to a call, left out.
  ///   - firstPrompt: the first prompt a transcript holds, read only for the last rule.
  public static func link(
    _ calls: [Call], among transcripts: [SubagentTranscriptInfo], taken: Set<URL> = [],
    firstPrompt: (URL) -> String?
  ) -> [String: SubagentTranscriptInfo] {
    var links: [String: SubagentTranscriptInfo] = [:]
    var used = taken
    var unlinked: [Call] = []
    for call in calls {
      if let found = transcripts.first(where: { $0.toolUseID == call.callID })
        ?? call.agentID.flatMap({ agent in transcripts.first { $0.agentID == agent } }),
        !used.contains(found.file)
      {
        links[call.callID] = found
        used.insert(found.file)
      } else {
        unlinked.append(call)
      }
    }
    // A transcript naming a call belongs to that call alone, even one not listed here.
    let anonymous = transcripts.filter { $0.toolUseID == nil && !used.contains($0.file) }
      .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    guard !anonymous.isEmpty else { return links }
    var prompts: [URL: String] = [:]
    for call in unlinked {
      guard let prompt = call.prompt, !prompt.isEmpty else { continue }
      let candidate = anonymous.first { transcript in
        guard !used.contains(transcript.file) else { return false }
        if let date = call.date, let created = transcript.createdAt,
          created < date.addingTimeInterval(-tolerance)
        {
          return false
        }
        if prompts[transcript.file] == nil { prompts[transcript.file] = firstPrompt(transcript.file) }
        return prompts[transcript.file] == prompt
      }
      if let candidate {
        links[call.callID] = candidate
        used.insert(candidate.file)
      }
    }
    return links
  }
}

extension ConversationEntry {
  /// The sub-agent this entry started, when it is one.
  public var subagentCall: ToolCall? {
    guard let call = toolCall, call.kind == .subagent else { return nil }
    return call
  }

  /// Every tool call, those in sub-agents' activities included, each after the sub-agent that
  /// made it.
  public static func allCalls(in entries: [ConversationEntry]) -> [ToolCall] {
    entries.flatMap { entry -> [ToolCall] in
      guard let call = entry.toolCall else { return [] }
      return [call] + (call.subagent?.activityEntries.map(allCalls(in:)) ?? [])
    }
  }

  /// Every sub-agent still running, at any depth, in the order they started.
  public static func runningSubagents(in entries: [ConversationEntry]) -> [ToolCall] {
    var found: [ToolCall] = []
    for entry in entries {
      guard let call = entry.subagentCall else { continue }
      if !call.state.isFinished { found.append(call) }
      if let inner = call.subagent?.activityEntries {
        found.append(contentsOf: runningSubagents(in: inner))
      }
    }
    return found
  }

  /// The sub-agent of that identifier, at any depth.
  public static func subagent(agentID: String, in entries: [ConversationEntry]) -> ToolCall? {
    for entry in entries {
      guard let call = entry.subagentCall else { continue }
      if call.subagent?.agentID == agentID { return call }
      if let inner = call.subagent?.activityEntries,
        let found = subagent(agentID: agentID, in: inner)
      {
        return found
      }
    }
    return nil
  }

  /// The sub-agent calls, at any depth, whose identifier is one of `callIDs`.
  public static func subagentCalls(_ callIDs: Set<String>, in entries: [ConversationEntry])
    -> [ToolCall]
  {
    var found: [ToolCall] = []
    for entry in entries {
      guard let call = entry.subagentCall else { continue }
      if callIDs.contains(call.callID) { found.append(call) }
      if let inner = call.subagent?.activityEntries {
        found.append(contentsOf: subagentCalls(callIDs, in: inner))
      }
    }
    return found
  }
}
