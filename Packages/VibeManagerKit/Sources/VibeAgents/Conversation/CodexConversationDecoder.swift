import Foundation
import VibeApplication

/// Reads a Codex rollout into conversation entries (#38).
///
/// Measured against 0.156 and 0.157. Codex writes every finished item of a turn as
/// `event_msg/item_completed`, already typed the way its app-server speaks: `UserMessage`,
/// `AgentMessage`, `Reasoning`, `CommandExecution` — whose `parsed_cmd` tells a `cat` from a `rg`
/// from anything else — `FileDiff` with a unified diff per file, `McpToolCall`… Only finished
/// items are written there: a call still running shows as a `response_item` whose output has not
/// come yet, and is shown as running until it does.
///
/// A rollout older than `item_completed` only has its `response_item` messages: they are shown,
/// with a notice saying the tools are missing.
public final class CodexConversationDecoder: ConversationDecoding {
  private var items: [ConversationEntry] = []
  private var legacy: [ConversationEntry] = []
  private var hasItems = false
  /// Calls whose output has not been written yet, by `call_id`.
  private var pendingCalls: [String: Int] = [:]

  public init() {}

  public var entries: [ConversationEntry] {
    if hasItems { return items }
    guard !legacy.isEmpty else { return [] }
    return [ConversationEntry(id: "codex:older-format", content: .notice(.olderFormat))] + legacy
  }

  public func consume(_ line: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let payload = object["payload"] as? [String: Any]
    else { return }
    let date = (object["timestamp"] as? String).flatMap(TranscriptDates.parse)
    switch (object["type"] as? String, payload["type"] as? String) {
    case ("event_msg", "item_completed"):
      guard let item = payload["item"] as? [String: Any] else { return }
      hasItems = true
      read(item: item, date: date)
    case ("event_msg", "turn_aborted"):
      interruptPending()
      items.append(
        ConversationEntry(
          id: "aborted:\(items.count)", date: date, content: .notice(.interrupted)))
    case ("response_item", "custom_tool_call"), ("response_item", "function_call"):
      startCall(payload, date: date)
    case ("response_item", "custom_tool_call_output"), ("response_item", "function_call_output"):
      if let callID = payload["call_id"] as? String { finishPending(callID) }
    case ("response_item", "message"):
      readLegacyMessage(payload, date: date)
    default:
      return
    }
  }

  // MARK: - Items

  private func read(item: [String: Any], date: Date?) {
    let id = item["id"] as? String ?? UUID().uuidString
    switch item["type"] as? String {
    case "UserMessage":
      let texts = Self.texts(item["content"]).filter { !Self.isContext($0) }
      let images = (item["content"] as? [[String: Any]] ?? []).filter {
        ($0["type"] as? String)?.lowercased().contains("image") == true
      }.count
      guard !texts.isEmpty || images > 0 else { return }
      append(
        ConversationEntry(
          id: id, date: date,
          content: .userPrompt(texts.joined(separator: "\n\n"), attachments: images)))
    case "AgentMessage":
      let text = Self.texts(item["content"]).joined(separator: "\n\n")
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      append(ConversationEntry(id: id, date: date, content: .agentText(text)))
    case "Reasoning":
      let summary = (item["summary_text"] as? [String] ?? []).joined(separator: "\n\n")
      append(
        ConversationEntry(id: id, date: date, content: .reasoning(summary.isEmpty ? nil : summary)))
    case "CommandExecution":
      append(ConversationEntry(id: id, date: date, content: .tool(Self.command(item, id: id))))
    case "FileChange":
      append(ConversationEntry(id: id, date: date, content: .tool(Self.fileChange(item, id: id))))
    case "McpToolCall":
      append(ConversationEntry(id: id, date: date, content: .tool(Self.mcp(item, id: id))))
    case "WebSearch":
      var call = ToolCall(callID: id, kind: .webSearch, state: .succeeded)
      if let query = item["query"] as? String { call.parameters = [ToolParameter(.query, query)] }
      append(ConversationEntry(id: id, date: date, content: .tool(call)))
    case "ImageView":
      let path = (item["path"] as? String).map { URL(string: $0)?.path ?? $0 }
      let call = ToolCall(
        callID: id, kind: .read, state: .succeeded,
        parameters: path.map { [ToolParameter(.path, $0)] } ?? [])
      append(ConversationEntry(id: id, date: date, content: .tool(call)))
    case "SubAgentActivity":
      guard item["kind"] as? String == "started" else { return }
      let path = item["agent_path"] as? String ?? ""
      let name = (path as NSString).lastPathComponent.replacingOccurrences(of: "_", with: " ")
      let call = ToolCall(
        callID: id, kind: .subagent, state: .succeeded,
        parameters: [ToolParameter(.description, name)])
      append(ConversationEntry(id: id, date: date, content: .tool(call)))
    case "Extension":
      // Codex's image generation: the image is saved to a file, whose path is kept. The image
      // itself, in base64 in the same item, is never decoded here.
      guard (item["kind"] as? String)?.hasPrefix("image_gen") == true else { return }
      var parameters: [ToolParameter] = []
      if let path = item["savedPath"] as? String { parameters.append(ToolParameter(.path, path)) }
      if let prompt = item["revisedPrompt"] as? String {
        parameters.append(ToolParameter(.prompt, prompt))
      }
      let failed = item["status"] as? String == "failed"
      let call = ToolCall(
        callID: id, kind: .image, state: failed ? .failed(exitCode: nil) : .succeeded,
        parameters: parameters)
      append(ConversationEntry(id: id, date: date, content: .tool(call)))
    case "ContextCompaction":
      append(ConversationEntry(id: id, date: date, content: .notice(.compacted)))
    default:
      return
    }
  }

  static func command(_ item: [String: Any], id: String) -> ToolCall {
    let script = Self.script(of: item["command"])
    let parsed = item["parsed_cmd"] as? [[String: Any]] ?? []
    let types = Set(parsed.compactMap { $0["type"] as? String })
    var parameters: [ToolParameter] = []
    let kind: ToolKind
    if types == ["read"] {
      kind = .read
      let paths = parsed.compactMap { $0["path"] as? String ?? $0["name"] as? String }
      if let path = paths.first { parameters.append(ToolParameter(.path, path)) }
    } else if types == ["search"] {
      kind = .search
      if let query = parsed.first?["query"] as? String {
        parameters.append(ToolParameter(.pattern, query))
      }
      if let path = parsed.first?["path"] as? String {
        parameters.append(ToolParameter(.path, path))
      }
    } else if types == ["list_files"] {
      kind = .list
      if let path = parsed.first?["path"] as? String {
        parameters.append(ToolParameter(.path, path))
      }
    } else {
      kind = .shell
    }
    parameters.append(ToolParameter(.command, script))
    if let cwd = item["cwd"] as? String { parameters.append(ToolParameter(.workingDirectory, cwd)) }
    let output = item["aggregated_output"] as? String ?? item["formatted_output"] as? String ?? ""
    let exitCode = (item["exit_code"] as? NSNumber).map { Int32(truncating: $0) }
    let failed = item["status"] as? String == "failed" || (exitCode ?? 0) != 0
    var call = ToolCall(
      callID: id, kind: kind, state: failed ? .failed(exitCode: exitCode) : .succeeded,
      parameters: parameters,
      output: output.isEmpty ? nil : ToolOutput.bounded(output, isError: failed))
    call.facts.exitCode = exitCode
    call.facts.duration = Self.duration(item["duration"])
    if kind == .shell {
      call.facts.tests = TestOutcomeRecognizer.outcome(of: script, output: output)
    }
    if kind == .search || kind == .list, !output.isEmpty {
      call.facts.resultCount = output.split(separator: "\n").count
    }
    return call
  }

  static func fileChange(_ item: [String: Any], id: String) -> ToolCall {
    let changes = (item["changes"] as? [String: [String: Any]] ?? [:]).sorted { $0.key < $1.key }
      .map { path, change -> FileDiff in
        let type = change["type"] as? String ?? "update"
        let diff = change["unified_diff"] as? String ?? ""
        let content = change["content"] as? String
        let (hunks, omitted) =
          diff.isEmpty && type == "add"
          ? UnifiedDiffParser.addition(of: content ?? "") : UnifiedDiffParser.hunks(in: diff)
        let kind: FileDiff.Kind =
          type == "add" ? .added : type == "delete" ? .deleted : .modified
        return FileDiff(path: path, kind: kind, hunks: hunks, omittedLineCount: omitted)
      }
    let allAdded = !changes.isEmpty && changes.allSatisfy { $0.kind == .added }
    let failed = item["status"] as? String == "failed"
    var call = ToolCall(
      callID: id, kind: allAdded ? .create : .edit,
      state: failed ? .failed(exitCode: nil) : .succeeded,
      parameters: changes.count == 1 ? [ToolParameter(.path, changes[0].path)] : [],
      changes: changes)
    call.facts.addedLines = changes.reduce(0) { $0 + $1.addedLineCount }
    call.facts.removedLines = changes.reduce(0) { $0 + $1.removedLineCount }
    if failed, let stderr = item["stderr"] as? String, !stderr.isEmpty {
      call.output = ToolOutput.bounded(stderr, isError: true)
    }
    return call
  }

  static func mcp(_ item: [String: Any], id: String) -> ToolCall {
    let server = item["server"] as? String ?? ""
    let tool = item["tool"] as? String ?? ""
    var parameters: [ToolParameter] = []
    if let arguments = item["arguments"] {
      let text =
        arguments as? String ?? ClaudeCodeConversationDecoder.compactJSON(arguments) ?? ""
      if !text.isEmpty { parameters.append(ToolParameter(.arguments, text)) }
    }
    let failed = item["status"] as? String == "failed"
    let result = item["result"] as? [String: Any]
    let text =
      ClaudeCodeConversationDecoder.text(of: result?["content"])
      + ((item["error"] as? String).map { "\n" + $0 } ?? "")
    var call = ToolCall(
      callID: id, kind: .mcp(server: server, tool: tool),
      state: failed ? .failed(exitCode: nil) : .succeeded, parameters: parameters,
      output: text.isEmpty ? nil : ToolOutput.bounded(text, isError: failed))
    call.facts.duration = Self.duration(item["duration"])
    return call
  }

  // MARK: - Calls still running

  private func startCall(_ payload: [String: Any], date: Date?) {
    guard let callID = payload["call_id"] as? String, pendingCalls[callID] == nil else { return }
    let input = payload["input"] as? String ?? payload["arguments"] as? String ?? ""
    let call = ToolCall(
      callID: callID, kind: .shell, state: .running,
      parameters: [ToolParameter(.command, Self.commandText(fromInput: input))])
    pendingCalls[callID] = items.count
    items.append(ConversationEntry(id: "running:\(callID)", date: date, content: .tool(call)))
  }

  private func finishPending(_ callID: String) {
    guard let index = pendingCalls.removeValue(forKey: callID) else { return }
    items.remove(at: index)
    for (key, value) in pendingCalls where value > index { pendingCalls[key] = value - 1 }
  }

  private func interruptPending() {
    for (_, index) in pendingCalls {
      guard case .tool(var call) = items[index].content else { continue }
      call.state = .interrupted
      items[index].content = .tool(call)
    }
    pendingCalls = [:]
  }

  /// A finished item replaces the running call it comes from, which is dropped when its output
  /// is written — already the case by the time the item is.
  private func append(_ entry: ConversationEntry) {
    items.append(entry)
  }

  // MARK: - Older rollouts

  private func readLegacyMessage(_ payload: [String: Any], date: Date?) {
    let role = payload["role"] as? String
    let texts = Self.texts(payload["content"]).filter { !Self.isContext($0) }
    guard role == "user" || role == "assistant", !texts.isEmpty else { return }
    let text = texts.joined(separator: "\n\n")
    let id = payload["id"] as? String ?? "legacy:\(legacy.count)"
    legacy.append(
      ConversationEntry(
        id: id, date: date,
        content: role == "user" ? .userPrompt(text, attachments: 0) : .agentText(text)))
  }

  // MARK: - Helpers

  static func texts(_ content: Any?) -> [String] {
    guard let blocks = content as? [[String: Any]] else {
      return (content as? String).map { [$0] } ?? []
    }
    return blocks.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
  }

  /// What Codex hands the model about its environment, dressed as a user message.
  static func isContext(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return ["<environment_context>", "<user_instructions>", "<permissions", "# AGENTS.md"]
      .contains { trimmed.hasPrefix($0) }
  }

  /// `["/bin/zsh", "-lc", "swift test"]` reads as `swift test`.
  static func script(of command: Any?) -> String {
    if let text = command as? String { return text }
    guard let argv = command as? [String] else { return "" }
    if argv.count >= 3, ["-lc", "-c"].contains(argv[argv.count - 2]) {
      return argv[argv.count - 1]
    }
    return argv.joined(separator: " ")
  }

  /// A call's input is the command itself, or JSON naming it.
  static func commandText(fromInput input: String) -> String {
    if let data = input.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      if let command = object["cmd"] as? String ?? object["command"] as? String { return command }
      if let argv = object["command"] as? [String] { return script(of: argv) }
    }
    return input
  }

  static func duration(_ value: Any?) -> Duration? {
    guard let value = value as? [String: Any], let seconds = value["secs"] as? Int else {
      return nil
    }
    return .seconds(seconds) + .nanoseconds(value["nanos"] as? Int ?? 0)
  }
}
