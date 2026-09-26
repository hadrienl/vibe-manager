import Foundation
import VibeApplication

/// Reads a Claude Code transcript into conversation entries (#38).
///
/// Measured against 2.1.275 to 2.1.282. One line per content block, not per message: a message's
/// text, reasoning and tool calls arrive on lines of their own, and a call's result comes back on a
/// `user` line naming it by `tool_use_id`, with a structured `toolUseResult` beside it — the patch
/// of an edit, the output of a command, the sub-agent a task started. That same result carries
/// the whole file an edit touched (`originalFile`): it is never kept.
///
/// Lines are shown in the order they were written. The `parentUuid` tree is not followed: calls
/// made in parallel branch it on every turn, so walking back from the last line would hide what
/// the agent did. A conversation rewound with `/rewind` therefore still shows what was abandoned.
public final class ClaudeCodeConversationDecoder: ConversationDecoding {
  public private(set) var entries: [ConversationEntry] = []
  private var indexByCallID: [String: Int] = [:]
  private let subagents: URL?

  /// - Parameter file: the transcript, whose sub-agents are written beside it, under
  ///   `<session id>/subagents/`.
  public init(file: URL?) {
    subagents = file.map {
      $0.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
    }
  }

  public func consume(_ line: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let type = object["type"] as? String
    else { return }
    if object["isSidechain"] as? Bool == true { return }
    let uuid = object["uuid"] as? String ?? UUID().uuidString
    let date = (object["timestamp"] as? String).flatMap(TranscriptDates.parse)
    switch type {
    case "assistant": readAssistant(object, uuid: uuid, date: date)
    case "user": readUser(object, uuid: uuid, date: date)
    case "system": readSystem(object, uuid: uuid, date: date)
    default: return
    }
  }

  // MARK: - Lines

  private func readAssistant(_ object: [String: Any], uuid: String, date: Date?) {
    guard let message = object["message"] as? [String: Any],
      let content = message["content"] as? [[String: Any]]
    else { return }
    if object["isApiErrorMessage"] as? Bool == true {
      let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
      append(ConversationEntry(id: uuid, date: date, content: .notice(.error(text))))
      return
    }
    for (index, block) in content.enumerated() {
      let id = index == 0 ? uuid : "\(uuid)#\(index)"
      switch block["type"] as? String {
      case "text":
        guard let text = block["text"] as? String,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { continue }
        append(ConversationEntry(id: id, date: date, content: .agentText(text)))
      case "thinking":
        let text = (block["thinking"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        append(ConversationEntry(id: id, date: date, content: .reasoning(text)))
      case "redacted_thinking":
        append(ConversationEntry(id: id, date: date, content: .reasoning(nil)))
      case "tool_use":
        guard let callID = block["id"] as? String, let name = block["name"] as? String else {
          continue
        }
        let input = block["input"] as? [String: Any] ?? [:]
        let call = Self.call(id: callID, name: name, input: input)
        indexByCallID[callID] = entries.count
        append(ConversationEntry(id: callID, date: date, content: .tool(call)))
      default:
        continue
      }
    }
  }

  private func readUser(_ object: [String: Any], uuid: String, date: Date?) {
    guard object["isMeta"] as? Bool != true, let message = object["message"] as? [String: Any]
    else { return }
    if object["isCompactSummary"] as? Bool == true {
      append(ConversationEntry(id: uuid, date: date, content: .notice(.compacted)))
      return
    }
    if let text = message["content"] as? String {
      readTypedText(text, uuid: uuid, date: date, attachments: 0)
      return
    }
    guard let content = message["content"] as? [[String: Any]] else { return }
    var texts: [String] = []
    var images = 0
    // `[Image #1]` or `[Image: source: …]` alone in a block: the CLI's placeholder for a picture.
    var placeholders = 0
    for block in content {
      switch block["type"] as? String {
      case "tool_result":
        apply(result: block, extra: object["toolUseResult"], denial: object["toolDenialKind"])
      case "image":
        images += 1
      case "text":
        guard let text = block["text"] as? String else { continue }
        if Self.isImagePlaceholder(text) {
          placeholders += 1
        } else {
          texts.append(text)
        }
      default:
        continue
      }
    }
    // A placeholder usually stands beside the image it names; count the picture once.
    let attachments = max(images, placeholders)
    guard !texts.isEmpty || attachments > 0 else { return }
    readTypedText(texts.joined(separator: "\n\n"), uuid: uuid, date: date, attachments: attachments)
  }

  /// What the user sent: a prompt, or one of the CLI's own messages dressed as one.
  private func readTypedText(_ text: String, uuid: String, date: Date?, attachments: Int) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("[Request interrupted by user") {
      interruptRunningCalls()
      append(ConversationEntry(id: uuid, date: date, content: .notice(.interrupted)))
      return
    }
    if trimmed.hasPrefix("<command-name>") {
      let name = Self.tag("command-name", in: trimmed) ?? ""
      let arguments = Self.tag("command-args", in: trimmed) ?? ""
      let command = [name, arguments].filter { !$0.isEmpty }.joined(separator: " ")
      append(ConversationEntry(id: uuid, date: date, content: .notice(.command(command))))
      return
    }
    if trimmed.hasPrefix("<bash-input>") {
      let command = Self.tag("bash-input", in: trimmed) ?? ""
      append(
        ConversationEntry(
          id: uuid, date: date, content: .notice(.shell(command: command, output: nil))))
      return
    }
    if trimmed.hasPrefix("<bash-stdout>") || trimmed.hasPrefix("<bash-stderr>") {
      let output = [Self.tag("bash-stdout", in: trimmed), Self.tag("bash-stderr", in: trimmed)]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
      if let index = entries.lastIndex(where: {
        if case .notice(.shell(_, nil)) = $0.content { return true }
        return false
      }), case .notice(.shell(let command, _)) = entries[index].content {
        entries[index].content = .notice(.shell(command: command, output: output))
      }
      return
    }
    // The CLI's own plumbing: command output, caveats, reminders, background task notices.
    if Self.isPlumbing(trimmed) { return }
    guard !trimmed.isEmpty || attachments > 0 else { return }
    append(
      ConversationEntry(id: uuid, date: date, content: .userPrompt(text, attachments: attachments)))
  }

  /// Tags the CLI wraps its own messages in. A prompt that merely starts with `<` — a pasted
  /// snippet, `<Button>` — is the user's.
  private static let plumbingTags = [
    "local-command-", "system-reminder", "task-notification", "agent-message",
    "cross-session-message", "command-message", "command-args", "user-prompt-submit-hook",
  ]

  static func isPlumbing(_ text: String) -> Bool {
    guard text.hasPrefix("<") else { return false }
    let name = text.dropFirst()
    return plumbingTags.contains { name.hasPrefix($0) }
  }

  static func isImagePlaceholder(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.range(of: #"^\[Image[^\]\n]*\]$"#, options: .regularExpression) != nil
  }

  private func readSystem(_ object: [String: Any], uuid: String, date: Date?) {
    switch object["subtype"] as? String {
    case "compact_boundary":
      append(ConversationEntry(id: uuid, date: date, content: .notice(.compacted)))
    case "away_summary", "informational", "scheduled_task_fire":
      guard let text = object["content"] as? String, !text.isEmpty else { return }
      append(ConversationEntry(id: uuid, date: date, content: .notice(.information(text))))
    default:
      return
    }
  }

  // MARK: - Results

  private func apply(result block: [String: Any], extra: Any?, denial: Any?) {
    guard let callID = block["tool_use_id"] as? String, let index = indexByCallID[callID],
      case .tool(var call) = entries[index].content
    else { return }
    let text = Self.text(of: block["content"])
    let details = extra as? [String: Any] ?? [:]
    let isError = block["is_error"] as? Bool == true
    if isError {
      if denial != nil || text.hasPrefix("The user doesn't want to proceed")
        || text.hasPrefix("Permission to use")
      {
        call.state = .refused
      } else if text.contains("interrupted by user") {
        call.state = .interrupted
      } else {
        let code = Self.exitCode(in: text)
        call.state = .failed(exitCode: code)
        call.facts.exitCode = code
      }
    } else {
      call.state = details["interrupted"] as? Bool == true ? .interrupted : .succeeded
    }
    readDetails(details, text: text, isError: isError, into: &call)
    entries[index].content = .tool(call)
  }

  private func readDetails(
    _ details: [String: Any], text: String, isError: Bool, into call: inout ToolCall
  ) {
    switch call.kind {
    case .shell:
      let stdout = details["stdout"] as? String
      let stderr = details["stderr"] as? String
      let printed =
        stdout == nil && stderr == nil
        ? text : [stdout, stderr].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
      call.output = ToolOutput.bounded(printed, isError: isError)
      call.facts.tests = TestOutcomeRecognizer.outcome(
        of: call.parameter(.command) ?? "", output: printed)
    case .edit, .create:
      let path = details["filePath"] as? String ?? call.parameter(.path) ?? ""
      if details["type"] as? String == "create", let content = details["content"] as? String {
        call.kind = .create
        let (hunks, omitted) = UnifiedDiffParser.addition(of: content)
        call.changes = [FileDiff(path: path, kind: .added, hunks: hunks, omittedLineCount: omitted)]
      } else if let patch = details["structuredPatch"] as? [[String: Any]] {
        if details["type"] as? String == "update" { call.kind = .edit }
        call.changes = [Self.change(path: path, patch: patch)]
      }
      call.facts.addedLines = call.changes.reduce(0) { $0 + $1.addedLineCount }
      call.facts.removedLines = call.changes.reduce(0) { $0 + $1.removedLineCount }
      if isError { call.output = ToolOutput.bounded(text, isError: true) }
    case .read:
      if let file = details["file"] as? [String: Any] {
        call.facts.lineCount = file["numLines"] as? Int
      }
      call.output = ToolOutput.bounded(text, isError: isError)
    case .search, .list:
      call.facts.resultCount =
        details["numFiles"] as? Int ?? details["numLines"] as? Int
        ?? (details["filenames"] as? [Any])?.count
      call.output = ToolOutput.bounded(text, isError: isError)
    case .subagent:
      if let agent = details["agentId"] as? String, let subagents {
        call.subTranscript = subagents.appendingPathComponent("agent-\(agent).jsonl")
      }
      call.output = ToolOutput.bounded(text, isError: isError)
    default:
      call.output = text.isEmpty ? nil : ToolOutput.bounded(text, isError: isError)
    }
  }

  private func interruptRunningCalls() {
    for index in entries.indices {
      guard case .tool(var call) = entries[index].content, !call.state.isFinished else { continue }
      call.state = .interrupted
      entries[index].content = .tool(call)
    }
  }

  private func append(_ entry: ConversationEntry) {
    entries.append(entry)
  }

  // MARK: - Calls

  static func call(id: String, name: String, input: [String: Any]) -> ToolCall {
    func string(_ key: String) -> String? {
      (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    var parameters: [ToolParameter] = []
    func add(_ key: ToolParameter.Key, _ value: String?) {
      if let value { parameters.append(ToolParameter(key, value)) }
    }
    let kind: ToolKind
    var summary: String?
    var facts = ToolFacts()
    switch name {
    case "Read":
      kind = .read
      add(.path, string("file_path"))
      if let offset = input["offset"] as? Int {
        let limit = input["limit"] as? Int
        add(.lines, limit.map { "\(offset)–\(offset + $0 - 1)" } ?? "\(offset)–")
      }
    case "Edit", "MultiEdit":
      kind = .edit
      add(.path, string("file_path"))
    case "NotebookEdit":
      kind = .edit
      add(.path, string("notebook_path"))
    case "Write":
      kind = .create
      add(.path, string("file_path"))
    case "Bash":
      kind = .shell
      add(.command, string("command"))
      summary = string("description")
    case "Grep":
      kind = .search
      add(.pattern, string("pattern"))
      add(.path, string("path") ?? string("glob"))
    case "Glob":
      kind = .search
      add(.pattern, string("pattern"))
      add(.path, string("path"))
    case "LS":
      kind = .list
      add(.path, string("path"))
    case "WebFetch":
      kind = .webFetch
      add(.url, string("url"))
      add(.prompt, string("prompt"))
    case "WebSearch":
      kind = .webSearch
      add(.query, string("query"))
    case "Task", "Agent":
      kind = .subagent
      add(.description, string("description"))
      add(.prompt, string("prompt"))
    case "TodoWrite":
      kind = .todo
      let todos = input["todos"] as? [[String: Any]] ?? []
      for todo in todos {
        let status = todo["status"] as? String ?? "pending"
        add(.todo, "\(status)\t\(todo["content"] as? String ?? "")")
      }
      facts.lineCount = todos.count
      facts.resultCount = todos.filter { $0["status"] as? String == "completed" }.count
    case "ExitPlanMode":
      kind = .plan
      add(.plan, string("plan"))
    case "AskUserQuestion":
      kind = .question
      for question in input["questions"] as? [[String: Any]] ?? [] {
        add(.question, question["question"] as? String)
        for option in question["options"] as? [[String: Any]] ?? [] {
          add(.arguments, option["label"] as? String)
        }
      }
    default:
      if name.hasPrefix("mcp__") {
        let parts = name.dropFirst(5).components(separatedBy: "__")
        kind = .mcp(server: parts.first ?? "", tool: parts.dropFirst().joined(separator: "__"))
      } else {
        kind = .other(name)
      }
      add(.arguments, Self.compactJSON(input))
    }
    return ToolCall(
      callID: id, kind: kind, parameters: parameters, facts: facts, summary: summary)
  }

  static func change(path: String, patch: [[String: Any]]) -> FileDiff {
    var hunks: [DiffHunk] = []
    var kept = 0
    var omitted = 0
    for hunk in patch {
      var oldLine = hunk["oldStart"] as? Int ?? 1
      var newLine = hunk["newStart"] as? Int ?? 1
      var lines: [DiffLine] = []
      for raw in hunk["lines"] as? [String] ?? [] {
        guard kept < DiffHunk.lineLimit else {
          omitted += 1
          continue
        }
        let body = String(raw.dropFirst())
        switch raw.first {
        case "+":
          lines.append(DiffLine(kind: .added, text: body, oldNumber: nil, newNumber: newLine))
          newLine += 1
        case "-":
          lines.append(DiffLine(kind: .removed, text: body, oldNumber: oldLine, newNumber: nil))
          oldLine += 1
        case "\\":
          continue
        default:
          lines.append(DiffLine(kind: .context, text: body, oldNumber: oldLine, newNumber: newLine))
          oldLine += 1
          newLine += 1
        }
        kept += 1
      }
      hunks.append(
        DiffHunk(
          oldStart: hunk["oldStart"] as? Int ?? 1, newStart: hunk["newStart"] as? Int ?? 1,
          lines: lines))
    }
    return FileDiff(path: path, kind: .modified, hunks: hunks, omittedLineCount: omitted)
  }

  // MARK: - Helpers

  static func text(of content: Any?) -> String {
    if let text = content as? String { return text }
    guard let blocks = content as? [[String: Any]] else { return "" }
    return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
      .joined(separator: "\n")
  }

  static func exitCode(in text: String) -> Int32? {
    guard text.hasPrefix("Exit code ") else { return nil }
    let digits = text.dropFirst("Exit code ".count).prefix { $0.isNumber || $0 == "-" }
    return Int32(digits)
  }

  static func tag(_ name: String, in text: String) -> String? {
    guard let start = text.range(of: "<\(name)>"),
      let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex)
    else { return nil }
    return String(text[start.upperBound..<end.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func compactJSON(_ object: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      data.count > 2
    else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    return text.count > 2_000 ? String(text.prefix(2_000)) + "…" : text
  }
}

/// The dates both CLIs write: ISO 8601, with or without fractions of a second.
enum TranscriptDates {
  nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  nonisolated(unsafe) private static let whole = ISO8601DateFormatter()
  private static let lock = NSLock()

  static func parse(_ text: String) -> Date? {
    lock.lock()
    defer { lock.unlock() }
    return fractional.date(from: text) ?? whole.date(from: text)
  }
}
