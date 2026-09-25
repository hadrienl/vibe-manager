import Foundation
import VibeApplication
import VibeDomain

/// Reads a session's transcripts for its journal (#36): the prompts, the tool calls, what the agent
/// said, the ends of its turns — and the output of the few commands that create a resource.
///
/// Apart from `AgentTranscriptReader` on purpose: that one follows the session on screen for Git,
/// this one every active session, from cursors the journal persists. One reader for both uses
/// would tie their rhythms together; reading a few new lines twice costs nothing.
public actor SessionJournalReader: SessionJournalReading {
  private let locator: AgentTranscriptLocator
  /// Bytes read at once, so that a transcript of hundreds of megabytes is never held whole.
  private let chunkSize: Int
  /// By file: the commands whose output is awaited, by call identifier. Kept for the run only —
  /// losing one across a relaunch loses a link a later line will usually give again.
  private var awaitedOutputs: [String: [String: (command: String, directory: String?)]] = [:]
  /// By Codex file: the folder its commands run from, when they do not say.
  private var codexDirectories: [String: String] = [:]

  public init(
    claudeProjects: URL = ClaudeCodeHome.projectsDirectory(),
    codexSessions: URL = CodexHome.sessionsDirectory(),
    chunkSize: Int = 4 << 20
  ) {
    locator = AgentTranscriptLocator(claudeProjects: claudeProjects, codexSessions: codexSessions)
    self.chunkSize = chunkSize
  }

  public func read(
    _ session: WorkSession, from cursors: [String: TranscriptCursor]
  ) async -> TranscriptReading {
    var reading = TranscriptReading(cursors: cursors)
    for conversation in session.conversations {
      guard
        let identifier = conversation.resumeIdentifier?.trimmingCharacters(
          in: .whitespacesAndNewlines),
        !identifier.isEmpty
      else { continue }
      let files: [URL]
      let isCodex: Bool
      switch conversation.providerID {
      case ClaudeCodeAgentProvider.id.rawValue:
        files = locator.claudeTranscripts(for: identifier)
        isCodex = false
      case CodexAgentProvider.id.rawValue:
        files = locator.codexRollouts(for: identifier, since: session.createdAt)
        isCodex = true
      default:
        continue
      }
      for file in files {
        reading.foundTranscript = true
        let (events, cursor) = advance(file, from: cursors[file.path], isCodex: isCodex)
        reading.cursors[file.path] = cursor
        reading.events += events.map { (conversation.providerID, $0) }
      }
    }
    return reading
  }

  /// The folders of every agent the session has had, and of its current one even before it has
  /// named its conversation: the first lines are written before the store knows which file they
  /// are in, and a folder not watched then would never wake the journal.
  public func transcriptDirectories(for session: WorkSession) async -> [String] {
    var directories: [String] = []
    let providers =
      session.conversations.map(\.providerID) + [session.agent?.providerID].compactMap { $0 }
    for providerID in providers {
      let directory: String
      switch providerID {
      case ClaudeCodeAgentProvider.id.rawValue: directory = locator.claudeProjects.path
      case CodexAgentProvider.id.rawValue: directory = locator.codexSessions.path
      default: continue
      }
      if !directories.contains(directory) { directories.append(directory) }
    }
    return directories
  }

  // MARK: - A file

  private func advance(
    _ file: URL, from cursor: TranscriptCursor?, isCodex: Bool
  ) -> ([TranscriptEvent], TranscriptCursor) {
    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
    let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    var cursor = cursor ?? TranscriptCursor(inode: inode)
    // A file shorter than what was read, or another file under the same name, was replaced: read
    // again from the start, which the resources' keys make harmless.
    if size < cursor.offset || (cursor.inode != nil && inode != nil && cursor.inode != inode) {
      cursor = TranscriptCursor(inode: inode)
      awaitedOutputs[file.path] = nil
    }
    cursor.inode = inode
    guard size > cursor.offset, let handle = try? FileHandle(forReadingFrom: file) else {
      return ([], cursor)
    }
    defer { try? handle.close() }
    var events: [TranscriptEvent] = []
    while cursor.offset < size {
      guard (try? handle.seek(toOffset: cursor.offset)) != nil,
        let data = try? handle.read(upToCount: chunkSize), !data.isEmpty
      else { break }
      // Only whole lines: the CLI may be writing the last one.
      guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
        // A line longer than a chunk: skipped whole rather than read forever, and the lines after
        // it read now.
        guard data.count == chunkSize else { break }
        cursor.offset += UInt64(data.count)
        continue
      }
      let complete = data[data.startIndex...lastNewline]
      cursor.offset += UInt64(complete.count)
      for line in complete.split(separator: UInt8(ascii: "\n")) {
        events +=
          isCodex
          ? codexEvents(Data(line), file: file.path)
          : claudeEvents(
            Data(line), file: file.path)
      }
    }
    return (events, cursor)
  }

  // MARK: - Claude Code

  private func claudeEvents(_ line: Data, file: String) -> [TranscriptEvent] {
    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
      return []
    }
    var awaited = awaitedOutputs[file] ?? [:]
    defer { awaitedOutputs[file] = awaited.isEmpty ? nil : awaited }
    return Self.claudeEvents(object, awaited: &awaited)
  }

  static func claudeEvents(
    _ object: [String: Any], awaited: inout [String: (command: String, directory: String?)]
  ) -> [TranscriptEvent] {
    let at = date(object["timestamp"])
    let directory = (object["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
    let branch = (object["gitBranch"] as? String).flatMap {
      $0.isEmpty || $0 == "HEAD" ? nil : $0
    }
    // A sub-agent's prompt is the main agent's words, and its ends of turn are not the session's.
    let isSidechain = object["isSidechain"] as? Bool ?? false
    if object["isMeta"] as? Bool == true || object["isCompactSummary"] as? Bool == true {
      return []
    }
    let message = object["message"] as? [String: Any]
    var events: [TranscriptEvent] = []
    switch object["type"] as? String {
    case "user":
      if let text = message?["content"] as? String {
        if !isSidechain, let prompt = userPrompt(text) { events.append(.prompt(prompt, at: at)) }
      } else if let items = message?["content"] as? [[String: Any]] {
        for item in items {
          switch item["type"] as? String {
          case "text":
            if !isSidechain, let prompt = userPrompt(item["text"] as? String ?? "") {
              events.append(.prompt(prompt, at: at))
            }
          case "tool_result":
            guard let id = item["tool_use_id"] as? String,
              let call = awaited.removeValue(forKey: id)
            else { continue }
            events.append(
              .creationOutput(
                command: call.command, directory: call.directory, output: text(of: item["content"]),
                at: at))
          default:
            break
          }
        }
      }
    case "assistant":
      for item in message?["content"] as? [[String: Any]] ?? [] {
        switch item["type"] as? String {
        case "text":
          if !isSidechain, let text = item["text"] as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            events.append(.agentText(text, at: at))
          }
        case "tool_use":
          guard let name = item["name"] as? String else { continue }
          let input = item["input"] as? [String: Any] ?? [:]
          let call = claudeToolCall(
            name: name, input: input, directory: directory, branch: branch, at: at)
          if let command = call.command, let id = item["id"] as? String,
            ResourceRecognizer.readsOutput(of: command)
          {
            awaited[id] = (command, directory)
          }
          events.append(.toolCall(call))
        default:
          break
        }
      }
      if !isSidechain, message?["stop_reason"] as? String == "end_turn" {
        events.append(.turnEnded(at: at))
      }
    case "system":
      if !isSidechain, object["subtype"] as? String == "turn_duration" {
        events.append(.turnEnded(at: at))
      }
    default:
      break
    }
    return events
  }

  /// What the user typed, not what the CLI slipped in on their behalf: a slash command's echo, its
  /// output, a reminder, an interruption.
  static func userPrompt(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    for injected in [
      "<command-", "<local-command", "<system-reminder", "<bash-", "<user-memory", "Caveat:",
      "[Request interrupted",
    ] where trimmed.hasPrefix(injected) {
      return nil
    }
    return trimmed
  }

  /// Tools that write a file: the URLs in what they write are code, not resources used.
  static let writingTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

  static func claudeToolCall(
    name: String, input: [String: Any], directory: String?, branch: String?, at: Date?
  ) -> TranscriptToolCall {
    let command = name == "Bash" ? input["command"] as? String : nil
    let subject: String?
    switch name {
    case "Bash":
      subject = command
    case "Edit", "Write", "MultiEdit", "Read", "NotebookEdit":
      subject = (input["file_path"] ?? input["notebook_path"]).flatMap { $0 as? String }.map {
        relative($0, to: directory)
      }
    case "Grep", "Glob":
      subject = input["pattern"] as? String
    case "WebFetch":
      subject = input["url"] as? String
    case "WebSearch":
      subject = input["query"] as? String
    case "Task", "Agent":
      subject = input["description"] as? String
    default:
      subject = compact(input)
    }
    var strings: [String] = []
    if !writingTools.contains(name) {
      collectStrings(input, into: &strings, skipping: name == "Bash" ? ["command"] : [])
    }
    return TranscriptToolCall(
      name: name, command: command, directory: directory, branch: branch, strings: strings,
      summary: subject.map { "\(toolName(name)): \($0)" } ?? toolName(name), at: at)
  }

  // MARK: - Codex

  private func codexEvents(_ line: Data, file: String) -> [TranscriptEvent] {
    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
      return []
    }
    var awaited = awaitedOutputs[file] ?? [:]
    var directory = codexDirectories[file]
    defer {
      awaitedOutputs[file] = awaited.isEmpty ? nil : awaited
      codexDirectories[file] = directory
    }
    return Self.codexEvents(object, directory: &directory, awaited: &awaited)
  }

  static func codexEvents(
    _ object: [String: Any], directory: inout String?,
    awaited: inout [String: (command: String, directory: String?)]
  ) -> [TranscriptEvent] {
    let at = date(object["timestamp"])
    guard let payload = object["payload"] as? [String: Any] else { return [] }
    switch object["type"] as? String {
    case "session_meta", "turn_context":
      if let cwd = payload["cwd"] as? String, cwd.hasPrefix("/") { directory = cwd }
      return []
    case "event_msg":
      return payload["type"] as? String == "task_complete" ? [.turnEnded(at: at)] : []
    case "response_item":
      break
    default:
      return []
    }
    switch payload["type"] as? String {
    case "message":
      let texts = (payload["content"] as? [[String: Any]] ?? []).compactMap {
        $0["text"] as? String
      }
      switch payload["role"] as? String {
      case "user":
        return texts.compactMap(codexPrompt).map { .prompt($0, at: at) }
      case "assistant":
        let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [.agentText(text, at: at)]
      default:
        return []
      }
    case "function_call", "custom_tool_call", "local_shell_call":
      let name = payload["name"] as? String ?? "shell"
      let calls = codexToolCalls(name: name, payload: payload, directory: directory, at: at)
      if let id = payload["call_id"] as? String,
        let command = calls.compactMap(\.command).first(where: ResourceRecognizer.readsOutput)
      {
        awaited[id] = (command, calls.first?.directory ?? directory)
      }
      return calls.map { .toolCall($0) }
    case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
      guard let id = payload["call_id"] as? String, let call = awaited.removeValue(forKey: id)
      else { return [] }
      return [
        .creationOutput(
          command: call.command, directory: call.directory, output: text(of: payload["output"]),
          at: at)
      ]
    default:
      return []
    }
  }

  /// Codex hands the model its instructions as user messages too.
  static func codexPrompt(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("# AGENTS.md") else {
      return nil
    }
    return trimmed
  }

  private static let commandPattern = try? NSRegularExpression(
    pattern: #""(cmd|workdir)"\s*:\s*("(?:[^"\\]|\\.)*")"#)

  /// Codex has changed the shape of its tool calls more than once: `shell` with an array,
  /// `exec_command` with a `cmd`, a JavaScript cell calling `exec_command` several times.
  static func codexToolCalls(
    name: String, payload: [String: Any], directory: String?, at: Date?
  ) -> [TranscriptToolCall] {
    var arguments: [String: Any] = [:]
    if let text = payload["arguments"] as? String,
      let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    {
      arguments = parsed
    } else if let action = payload["action"] as? [String: Any] {
      arguments = action
    }
    let workdir = (arguments["workdir"] as? String) ?? (arguments["working_directory"] as? String)
    var commands: [(command: String, directory: String?)] = []
    if let command = arguments["cmd"] as? String {
      commands.append((command, workdir ?? directory))
    } else if let command = arguments["command"] as? [String], !command.isEmpty {
      // `["bash", "-lc", "…"]`: the script is the command.
      let line =
        command.count >= 3 && ["-lc", "-c"].contains(command[1])
        ? command[command.count - 1]
        : command.joined(separator: " ")
      commands.append((line, workdir ?? directory))
    } else if let command = arguments["command"] as? String {
      commands.append((command, workdir ?? directory))
    } else if let input = payload["input"] as? String, name != "apply_patch" {
      // JavaScript: every `exec_command` of the cell, with its own folder.
      let range = NSRange(input.startIndex..., in: input)
      for match in commandPattern?.matches(in: input, range: range) ?? [] {
        guard let keyRange = Range(match.range(at: 1), in: input),
          let valueRange = Range(match.range(at: 2), in: input),
          let value =
            (try? JSONSerialization.jsonObject(
              with: Data(input[valueRange].utf8), options: .fragmentsAllowed)) as? String
        else { continue }
        if input[keyRange] == "cmd" {
          commands.append((value, directory))
        } else if let last = commands.indices.last {
          commands[last].directory = value
        }
      }
    }
    if !commands.isEmpty {
      return commands.map { command in
        TranscriptToolCall(
          name: name, command: command.command, directory: command.directory,
          summary: "\(name): \(command.command)", at: at)
      }
    }
    var strings: [String] = []
    if name != "apply_patch" { collectStrings(arguments, into: &strings, skipping: []) }
    let subject: String
    if name == "apply_patch", let input = payload["input"] as? String {
      subject = patchedFiles(input).map { relative($0, to: directory) }.joined(separator: ", ")
    } else {
      subject = compact(arguments) ?? ""
    }
    return [
      TranscriptToolCall(
        name: name, directory: directory, strings: strings,
        summary: subject.isEmpty ? name : "\(name): \(subject)", at: at)
    ]
  }

  static func patchedFiles(_ patch: String) -> [String] {
    patch.split(separator: "\n").compactMap { line in
      for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
      where line.hasPrefix(prefix) {
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
      }
      return nil
    }
  }

  // MARK: - Helpers

  static func date(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
  }

  /// The text of a tool's result: a string, or blocks of text.
  static func text(of content: Any?) -> String {
    if let text = content as? String { return text }
    if let items = content as? [[String: Any]] {
      return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    return ""
  }

  static func collectStrings(_ value: Any, into strings: inout [String], skipping: Set<String>) {
    if let text = value as? String {
      strings.append(text)
    } else if let dictionary = value as? [String: Any] {
      for (key, inner) in dictionary where !skipping.contains(key) {
        collectStrings(inner, into: &strings, skipping: [])
      }
    } else if let array = value as? [Any] {
      for inner in array { collectStrings(inner, into: &strings, skipping: []) }
    }
  }

  /// `mcp__gitlab__issues` reads `gitlab.issues`.
  static func toolName(_ name: String) -> String {
    guard name.hasPrefix("mcp__") else { return name }
    let parts = name.dropFirst(5).components(separatedBy: "__")
    return "mcp " + parts.joined(separator: ".")
  }

  /// The arguments of a call on one line, its keys sorted.
  static func compact(_ arguments: [String: Any]) -> String? {
    guard !arguments.isEmpty,
      let data = try? JSONSerialization.data(
        withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return nil }
    return String(decoding: data.prefix(200), as: UTF8.self)
  }

  static func relative(_ path: String, to directory: String?) -> String {
    guard let directory, path.hasPrefix(directory + "/") else { return path }
    return String(path.dropFirst(directory.count + 1))
  }
}
