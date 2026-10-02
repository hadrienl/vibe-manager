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
///
/// A sub-agent (#180, measured against 2.1.284 and 2.1.285) is an `Agent` call — or a skill run
/// apart, a `Skill` call whose result says `forked`. Most return at once (`async_launched`, with the
/// sub-agent's `agentId`) and end later: a `<task-notification>` names the call, its status, what it
/// used and, sometimes, its answer; otherwise the answer comes as a hand-back, a message from the
/// sub-agent (`origin.handback`). Its own transcript is decoded by this same class, as a sub-agent's.
public final class ClaudeCodeConversationDecoder: ConversationDecoding {
  public private(set) var entries: [ConversationEntry] = []
  private var indexByCallID: [String: Int] = [:]
  /// Sub-agent calls by the sub-agent's identifier, once the call returned it.
  private var indexByAgentID: [String: Int] = [:]
  /// Whether this is a sub-agent's own transcript: its lines are all `isSidechain`, its first
  /// prompt is its mission — shown by the call that started it — and its hand-back is its answer.
  private let isSubagent: Bool
  private var hasSeenMission = false
  /// Where the line being decoded is, for the images it holds (#209).
  private var location: TranscriptLineLocation?

  /// - Parameter isSubagent: a sub-agent's own transcript, written beside the conversation's under
  ///   `<session id>/subagents/`, rather than the conversation's.
  public init(isSubagent: Bool = false) {
    self.isSubagent = isSubagent
  }

  public func consume(_ record: TranscriptRecord) {
    let object = record.object
    location = record.location
    guard let type = object["type"] as? String
    else { return }
    if object["isSidechain"] as? Bool == true, !isSubagent { return }
    let uuid = object["uuid"] as? String ?? UUID().uuidString
    let date = (object["timestamp"] as? String).flatMap(TranscriptDates.parse)
    switch type {
    case "assistant": readAssistant(object, uuid: uuid, date: date)
    case "user": readUser(object, uuid: uuid, date: date)
    case "system": readSystem(object, uuid: uuid, date: date)
    case "attachment": readAttachment(object, uuid: uuid, date: date)
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
        // A sub-agent's hand-back is its answer, shown as such by the call that started it.
        if isSubagent, name == "SubagentHandback" { continue }
        var call = Self.call(id: callID, name: name, input: input)
        if call.kind == .subagent { call.subagent?.startedAt = date }
        if name == "SendMessage", let agent = input["to"] as? String {
          resume(agent: agent)
        }
        indexByCallID[callID] = entries.count
        append(ConversationEntry(id: callID, date: date, content: .tool(call)))
      default:
        continue
      }
    }
  }

  private func readUser(_ object: [String: Any], uuid: String, date: Date?) {
    if let origin = object["origin"] as? [String: Any], origin["handback"] as? Bool == true,
      let agent = origin["from"] as? String, let body = origin["body"] as? String
    {
      readHandback(body, from: agent)
      return
    }
    if object["isMeta"] as? Bool == true {
      readImageSources(object)
      return
    }
    guard let message = object["message"] as? [String: Any]
    else { return }
    if object["isCompactSummary"] as? Bool == true {
      append(ConversationEntry(id: uuid, date: date, content: .notice(.compacted)))
      return
    }
    if let text = message["content"] as? String {
      if text.hasPrefix("<task-notification>") {
        readNotification(text)
        return
      }
      if isSubagent, !hasSeenMission {
        hasSeenMission = true
        return
      }
      readTypedText(text, uuid: uuid, date: date, attachments: [])
      return
    }
    guard let content = message["content"] as? [[String: Any]] else { return }
    if isSubagent, !hasSeenMission,
      !content.contains(where: { $0["type"] as? String == "tool_result" })
    {
      hasSeenMission = true
      return
    }
    readBlocks(content, in: ["message", "content"], uuid: uuid, date: date) { block in
      apply(result: block, extra: object["toolUseResult"], denial: object["toolDenialKind"])
    }
  }

  /// A prompt the user sent while the agent worked: Claude Code hands it to the turn under way
  /// and writes it as an attachment of that turn, never as a user line. Background task notices
  /// and other sessions' messages travel the same way; only what a person typed is a prompt.
  private func readAttachment(_ object: [String: Any], uuid: String, date: Date?) {
    guard let attachment = object["attachment"] as? [String: Any],
      attachment["type"] as? String == "queued_command"
    else { return }
    if attachment["commandMode"] as? String == "task-notification",
      let text = attachment["prompt"] as? String
    {
      readNotification(text)
      return
    }
    guard attachment["commandMode"] as? String == "prompt" else { return }
    let origin = (attachment["origin"] as? [String: Any])?["kind"] as? String
    guard origin == nil || origin == "human" else { return }
    if let text = attachment["prompt"] as? String {
      readTypedText(text, uuid: uuid, date: date, attachments: [])
    } else if let content = attachment["prompt"] as? [[String: Any]] {
      readBlocks(content, in: ["attachment", "prompt"], uuid: uuid, date: date) { _ in }
    }
  }

  /// A prompt's blocks: its text, and the images that came with it (#209).
  ///
  /// The CLI writes a placeholder for each image — `[Image #1]` where it was pasted, inside the
  /// text, or `[Image: source: /path]` in a block of its own for a file — and the images, in the
  /// same order: the n-th placeholder names the n-th image. An image keeps where its bytes are,
  /// never the bytes.
  private func readBlocks(
    _ content: [[String: Any]], in container: [String], uuid: String, date: Date?,
    result: ([String: Any]) -> Void
  ) {
    var texts: [String] = []
    var images: [(embedded: EmbeddedImage?, mediaType: String)] = []
    // The file each placeholder names, nil for a pasted image.
    var placeholders: [String?] = []
    for (index, block) in content.enumerated() {
      switch block["type"] as? String {
      case "tool_result":
        result(block)
      case "image":
        let encoded = EmbeddedImage.encodedImage(in: block)
        let mediaType = encoded?.mediaType ?? "image/png"
        var embedded: EmbeddedImage?
        if let location, let encoded {
          embedded = EmbeddedImage(
            line: location, container: container, index: index, mediaType: mediaType,
            encodedLength: (encoded.base64 as NSString).length)
        }
        images.append((embedded, mediaType))
      case "text":
        guard let text = block["text"] as? String else { continue }
        if Self.isImagePlaceholder(text) {
          placeholders.append(Self.imageSource(text))
          continue
        }
        // `[Image #1] [Image #2]Look at this`: the CLI writes its placeholders where the images
        // were pasted, inside the text.
        let (stripped, inline) = Self.strippingInlinePlaceholders(text)
        placeholders += [String?](repeating: nil, count: inline)
        if !stripped.isEmpty { texts.append(stripped) }
      default:
        continue
      }
    }
    // A placeholder usually stands beside the image it names; each picture is counted once.
    let attachments = (0..<max(images.count, placeholders.count)).map { rank in
      let path = rank < placeholders.count ? placeholders[rank] : nil
      let image = rank < images.count ? images[rank] : nil
      return Self.image(
        id: "\(uuid)/attachment-\(rank)", path: path, embedded: image?.embedded,
        mediaType: image?.mediaType)
    }
    guard !texts.isEmpty || !attachments.isEmpty else { return }
    readTypedText(texts.joined(separator: "\n\n"), uuid: uuid, date: date, attachments: attachments)
  }

  /// The files of the images a prompt held (#209). Measured against 2.1.261 to 2.1.286: the prompt
  /// is written `[Image #1]` and its image; the file each came from follows on a line of its own,
  /// `isMeta`, of `[Image: source: /path]` blocks — a line or two later. Each path goes, in order,
  /// to the images of the last prompt that have no file yet.
  private func readImageSources(_ object: [String: Any]) {
    guard let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]],
      !content.isEmpty
    else { return }
    var paths: [String] = []
    for block in content {
      guard block["type"] as? String == "text", let text = block["text"] as? String,
        Self.isImagePlaceholder(text), let path = Self.imageSource(text)
      else { return }
      paths.append(path)
    }
    guard let index = entries.lastIndex(where: \.isUserPrompt),
      case .userPrompt(let text, var attachments) = entries[index].content
    else { return }
    var remaining = paths[...]
    for rank in attachments.indices
    where attachments[rank].kind == .image && attachments[rank].file == nil {
      guard let path = remaining.popFirst() else { break }
      let named = Self.image(
        id: attachments[rank].id, path: path, embedded: attachments[rank].embeddedImage,
        mediaType: attachments[rank].embeddedImage?.mediaType)
      attachments[rank] = named
    }
    entries[index].content = .userPrompt(text, attachments: attachments)
  }

  /// An image of a prompt: its file when the CLI named one, its bytes in the transcript when it
  /// holds them, both when it can.
  static func image(id: String, path: String?, embedded: EmbeddedImage?, mediaType: String?)
    -> MessageAttachment
  {
    let file = path.map { URL(fileURLWithPath: $0) }
    let source: MessageAttachment.Source =
      switch (file, embedded) {
      case (let file?, let embedded?): .fileWithEmbedded(file, embedded)
      case (let file?, nil): .file(file)
      case (nil, let embedded?): .embedded(embedded)
      case (nil, nil): .missing
      }
    let kind =
      file.map { MessageAttachment.kind(forExtension: $0.pathExtension) }
      ?? mediaType.map(MessageAttachment.kind(forMediaType:)) ?? .image
    return MessageAttachment(
      id: id, kind: kind == .other ? .image : kind, source: source, name: file?.lastPathComponent)
  }

  /// The file an `[Image: source: /path]` placeholder names; nil for `[Image #1]`.
  static func imageSource(_ placeholder: String) -> String? {
    let trimmed = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "[Image: source: "
    guard trimmed.hasPrefix(prefix), trimmed.hasSuffix("]") else { return nil }
    let path = String(trimmed.dropFirst(prefix.count).dropLast())
      .trimmingCharacters(in: .whitespaces)
    return path.hasPrefix("/") ? path : nil
  }

  /// What the user sent: a prompt, or one of the CLI's own messages dressed as one.
  private func readTypedText(
    _ text: String, uuid: String, date: Date?, attachments: [MessageAttachment]
  ) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("[Request interrupted by user") {
      interruptRunningCalls()
      append(ConversationEntry(id: uuid, date: date, content: .notice(.interrupted)))
      return
    }
    // A skill invoked opens on `<command-message>` (2.1.285), a command on `<command-name>`:
    // both are the command the user typed (#219).
    if trimmed.hasPrefix("<command-name>")
      || (trimmed.hasPrefix("<command-message>") && trimmed.contains("<command-name>"))
    {
      let name = Self.tag("command-name", in: trimmed) ?? ""
      let arguments = Self.tag("command-args", in: trimmed) ?? ""
      let command = [name, arguments].filter { !$0.isEmpty }.joined(separator: " ")
      append(ConversationEntry(id: uuid, date: date, content: .notice(.command(command))))
      return
    }
    // A command run with `!` (#188): measured against 2.1.285, its input is written when it
    // starts, its output when it ends — stdout and stderr both, the latter most often empty, the
    // shell sending both streams to the first. No exit code is written.
    if trimmed.hasPrefix("<bash-input>") {
      let command = Self.tag("bash-input", in: trimmed) ?? ""
      append(
        ConversationEntry(
          id: uuid, date: date, content: .notice(.shell(ShellRun(command: command)))))
      return
    }
    if trimmed.hasPrefix("<bash-stdout>") || trimmed.hasPrefix("<bash-stderr>") {
      if let index = entries.lastIndex(where: { $0.shellRun?.state == .running }),
        var run = entries[index].shellRun
      {
        run.state = .succeeded
        run.output = Self.tag("bash-stdout", in: trimmed).flatMap { Self.shellOutput($0) }
        run.errorOutput = Self.tag("bash-stderr", in: trimmed).flatMap {
          Self.shellOutput($0, isError: true)
        }
        entries[index].content = .notice(.shell(run))
      }
      return
    }
    // The CLI's own plumbing: command output, caveats, reminders, background task notices.
    if Self.isPlumbing(trimmed) { return }
    // The files the composer joined by their paths, at the end of the text (#209).
    let joined = AttachedPaths.split(text).files.enumerated().map { rank, file in
      MessageAttachment.file(file, id: "\(uuid)/file-\(rank)", isWrittenInText: true)
    }
    let all = attachments + joined
    guard !trimmed.isEmpty || !all.isEmpty else { return }
    append(ConversationEntry(id: uuid, date: date, content: .userPrompt(text, attachments: all)))
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

  private static let inlinePlaceholder = try? NSRegularExpression(
    pattern: #"\[Image #\d+\][ \t]*"#)

  /// The text without the `[Image #N]` placeholders written in it, and how many there were.
  static func strippingInlinePlaceholders(_ text: String) -> (text: String, count: Int) {
    let range = NSRange(text.startIndex..., in: text)
    guard let inlinePlaceholder else { return (text, 0) }
    let count = inlinePlaceholder.numberOfMatches(in: text, range: range)
    guard count > 0 else { return (text, 0) }
    let stripped = inlinePlaceholder.stringByReplacingMatches(
      in: text, range: range, withTemplate: "")
    return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), count)
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
    if call.kind == .other("Skill"), details["status"] as? String == "forked",
      details["agentId"] is String
    {
      Self.forkSkill(&call, details: details, startedAt: entries[index].date)
    }
    if call.kind == .subagent {
      readSubagentResult(details, text: text, isError: isError, into: &call, at: index)
    } else {
      readDetails(details, text: text, isError: isError, into: &call)
    }
    entries[index].content = .tool(call)
  }

  // MARK: - Sub-agents

  /// A skill run apart is a sub-agent named after the skill.
  static func forkSkill(_ call: inout ToolCall, details: [String: Any], startedAt: Date?) {
    let name = details["commandName"] as? String
    var words = name.map { ["/" + $0] } ?? []
    if let json = call.parameter(.arguments), let data = json.data(using: .utf8),
      let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let arguments = input["args"] as? String, !arguments.isEmpty
    {
      words.append(arguments)
    }
    call.kind = .subagent
    call.parameters =
      words.isEmpty ? [] : [ToolParameter(.description, words.joined(separator: " "))]
    call.subagent = SubagentRun(
      type: name, mode: details["background"] as? Bool == false ? .foreground : .background,
      startedAt: startedAt)
  }

  /// What a sub-agent's call returned: the sub-agent itself when it runs in the background, its
  /// answer when it ran in front.
  private func readSubagentResult(
    _ details: [String: Any], text: String, isError: Bool, into call: inout ToolCall, at index: Int
  ) {
    var run = call.subagent ?? SubagentRun()
    if let agent = details["agentId"] as? String {
      run.agentID = agent
      indexByAgentID[agent] = index
    }
    let status = details["status"] as? String
    call.output = nil
    if !isError, status == "async_launched" || (status == "forked" && run.mode == .background) {
      // Started, not done: its end is notified later.
      run.mode = .background
      call.state = .running
    } else if isError {
      if case .failed = call.state { run.failure = Self.bounded(text) }
    } else {
      let answer = status == "forked" ? details["result"] as? String ?? text : text
      run.result = answer.isEmpty ? nil : Self.bounded(answer)
      run.usage = SubagentUsage(
        toolUses: details["totalToolUseCount"] as? Int,
        duration: (details["totalDurationMs"] as? Int).map { .milliseconds($0) },
        tokens: details["totalTokens"] as? Int)
    }
    call.subagent = run
  }

  /// A sub-agent's end, notified to the agent: `completed`, `failed`, `killed` or `stopped`. The
  /// same sub-agent notifies again when it is given more work: the last word stands. It is known by
  /// its identifier first: once resumed, the notification names the message that resumed it.
  private func readNotification(_ text: String) {
    guard
      let index = Self.tag("task-id", in: text).flatMap({ indexByAgentID[$0] })
        ?? Self.tag("tool-use-id", in: text).flatMap({ indexByCallID[$0] }),
      case .tool(var call) = entries[index].content, call.kind == .subagent
    else { return }
    var run = call.subagent ?? SubagentRun()
    let status = Self.tag("status", in: text)
    switch status {
    case "completed": call.state = .succeeded
    case "failed": call.state = .failed(exitCode: nil)
    case "killed", "stopped": call.state = .interrupted
    default: return
    }
    if let agent = Self.tag("task-id", in: text), run.agentID == nil {
      run.agentID = agent
      indexByAgentID[agent] = index
    }
    let result = Self.tag("result", in: text) ?? ""
    // "This agent's report was delivered to you as a message": the hand-back holds it.
    if status == "completed", !result.isEmpty, !result.contains("delivered to you as a message") {
      run.result = Self.bounded(result)
    }
    if status == "failed" {
      let summary = Self.tag("summary", in: text) ?? ""
      let reason = summary.range(of: " failed: ").map { String(summary[$0.upperBound...]) }
      run.failure = Self.bounded(reason ?? summary)
    }
    run.usage = SubagentUsage(
      toolUses: Self.tag("tool_uses", in: text).flatMap { Int($0) },
      duration: Self.tag("duration_ms", in: text).flatMap { Int($0) }.map { .milliseconds($0) },
      tokens: Self.tag("subagent_tokens", in: text).flatMap { Int($0) })
    call.subagent = run
    entries[index].content = .tool(call)
  }

  /// A sub-agent's answer, handed back as a message: the report, whose every line the CLI
  /// indents by two spaces, follows a frame of its own.
  private func readHandback(_ body: String, from agent: String) {
    guard let index = indexByAgentID[agent], case .tool(var call) = entries[index].content,
      var run = call.subagent
    else { return }
    let report = body.range(of: "The report follows:\n").map { String(body[$0.upperBound...]) }
    guard let report else { return }
    let lines = report.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      line.hasPrefix("  ") ? line.dropFirst(2) : line
    }
    run.result = Self.bounded(lines.joined(separator: "\n"))
    call.subagent = run
    entries[index].content = .tool(call)
  }

  /// A sub-agent given more work by a message: it runs again, its last answer kept until the next.
  private func resume(agent: String) {
    guard let index = indexByAgentID[agent], case .tool(var call) = entries[index].content,
      call.subagent?.mode == .background, call.state.isFinished
    else { return }
    call.state = .running
    entries[index].content = .tool(call)
  }

  static func bounded(_ text: String) -> String {
    ToolOutput.bounded(text.trimmingCharacters(in: .whitespacesAndNewlines)).text
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
    case .question:
      // The answers, by question, beside what the agent was told: shown on the options.
      guard !isError, let answers = details["answers"] as? [String: String], !answers.isEmpty
      else {
        call.output = text.isEmpty ? nil : ToolOutput.bounded(text, isError: isError)
        return
      }
      call.parameters = Self.answering(call.parameters, with: answers)
    default:
      call.output = text.isEmpty ? nil : ToolOutput.bounded(text, isError: isError)
    }
  }

  /// Each question's parameters followed by its answer, when it has one.
  static func answering(_ parameters: [ToolParameter], with answers: [String: String])
    -> [ToolParameter]
  {
    var result: [ToolParameter] = []
    var question: String?
    func close() {
      if let question, let answer = answers[question] {
        result.append(ToolParameter(.answer, answer))
      }
    }
    for parameter in parameters where parameter.key != .answer {
      if parameter.key == .question {
        close()
        question = parameter.value
      }
      result.append(parameter)
    }
    close()
    return result
  }

  /// The user stopped the turn. A sub-agent in the background goes on: only its notification, or
  /// the user stopping it, ends it.
  private func interruptRunningCalls() {
    for index in entries.indices {
      if var run = entries[index].shellRun, run.state == .running {
        run.state = .interrupted
        entries[index].content = .notice(.shell(run))
        continue
      }
      guard case .tool(var call) = entries[index].content, !call.state.isFinished,
        call.subagent?.mode != .background
      else { continue }
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
    var subagent: SubagentRun?
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
      subagent = SubagentRun(
        type: string("subagent_type") ?? string("name"),
        mode: input["run_in_background"] as? Bool == true ? .background : .foreground)
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
        if question["multiSelect"] as? Bool == true { add(.multipleChoices, "true") }
        for option in question["options"] as? [[String: Any]] ?? [] {
          guard let label = option["label"] as? String else { continue }
          add(.arguments, label)
          add(.preview, AgentRequestReading.preview(of: option))
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
      callID: id, kind: kind, parameters: parameters, facts: facts, summary: summary,
      subagent: subagent)
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

  static func shellOutput(_ text: String, isError: Bool = false) -> ToolOutput? {
    let trimmed = text.trimmingCharacters(in: .newlines)
    return trimmed.isEmpty ? nil : ToolOutput.bounded(trimmed, isError: isError)
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
