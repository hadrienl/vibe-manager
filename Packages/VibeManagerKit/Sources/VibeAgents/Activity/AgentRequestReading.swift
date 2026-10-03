import Foundation
import VibeApplication

/// Reads what an agent asks out of the JSON its hooks were handed (#40).
///
/// The shape is Claude Code's — `tool_name`, `tool_input`, `permission_suggestions` — which
/// Codex's hooks share for what they report. A payload cut at the hook's byte limit is no longer
/// JSON: the request is then `unreadable`, and what would be allowed is never guessed.
enum AgentRequestReading {
  /// The keys whose first value tells one tool call from another, most telling first. The hooks
  /// that report a tool finishing keep exactly these (`AgentActivityHookCommand.Payload.fields`).
  static let subjectKeys = ["command", "file_path", "url"]
  /// What the hooks of a finishing tool keep: enough to tell which request it settles.
  static let resolutionFields = ["agent_id", "tool_name"] + subjectKeys
  /// The most of a plan a card shows; the rest is read in the session.
  static let planExcerptLineLimit = 40
  /// The most of a tool's input kept for "Show all".
  static let detailsByteLimit = 16 * 1024

  /// The call a report is about, read the same way from a request and from the tool that settles
  /// it: the first value of each key, wherever it sits in the JSON text.
  static func reference(of event: AgentActivityEvent) -> AgentToolReference {
    let text = event.payload.map { String(decoding: $0, as: UTF8.self) } ?? ""
    return AgentToolReference(
      tool: firstString("tool_name", in: text),
      agentID: firstString("agent_id", in: text),
      subject: subjectKeys.lazy.compactMap { firstString($0, in: text) }.first
    )
  }

  /// The first string value of `key` in a JSON text, escapes resolved. A text cut short still
  /// gives the values it holds whole.
  static func firstString(_ key: String, in text: String) -> String? {
    let pattern = "\"" + NSRegularExpression.escapedPattern(for: key) + #"": ?"((?:[^"\\]|\\.)*)""#
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    let literal = "\"" + text[range] + "\""
    return (try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed))
      as? String
  }

  /// The beginning of the first string value of `key` in a JSON text cut inside that value:
  /// whatever the cut left of it, escapes resolved. `nil` when the text holds no such value.
  static func leadingString(_ key: String, in text: String) -> String? {
    let pattern = "\"" + NSRegularExpression.escapedPattern(for: key) + #"": ?"((?:[^"\\]|\\.)*)"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    var value = Substring(text[range])
    // What the cut split: an escape short of its end — an odd run of backslashes, `\u` short of
    // its digits — or the first half of a character written as two escapes.
    let unfinished = [
      #"(?<!\\)(?:\\\\)*\\(?:u[0-9A-Fa-f]{0,3})?$"#,
      #"(?<!\\)(?:\\\\)*\\u[dD][89abAB][0-9A-Fa-f]{2}$"#,
    ]
    for pattern in unfinished {
      guard let tail = value.range(of: pattern, options: .regularExpression) else { continue }
      // The pairs of backslashes before the escape are whole: they stay.
      let pairs = value[tail].prefix { $0 == "\\" }.count / 2 * 2
      value = value[..<value.index(tail.lowerBound, offsetBy: pairs)]
    }
    let literal = "\"" + value + "\""
    return (try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed))
      as? String
  }

  // MARK: - Content

  /// What the report asks, or `unreadable` when it cannot be read whole. `alwaysAllow` says what
  /// the CLI offers beyond "once" when its report does not.
  static func content(
    of event: AgentActivityEvent,
    alwaysAllow fallback: (String) -> AgentAlwaysAllow? = { _ in nil }
  ) -> AgentRequestContent {
    guard let object = event.jsonObject, let toolName = object["tool_name"] as? String else {
      let tool = reference(of: event).tool
      // A plan past the byte limit: the cut holds its beginning, more than a card shows. Its file
      // is named after it, and lost with the rest (checked against 2.1.288).
      if tool == "ExitPlanMode", let text = event.payload.map({ String(decoding: $0, as: UTF8.self) }),
        let beginning = leadingString("plan", in: text)
      {
        return plan(beginning, isCut: true)
      }
      return .unreadable(tool: tool)
    }
    let input = object["tool_input"] as? [String: Any] ?? [:]
    switch toolName {
    case "AskUserQuestion", "request_user_input":
      let questions = questions(in: input)
      return questions.isEmpty ? .unreadable(tool: toolName) : .questions(questions)
    case "ExitPlanMode":
      return plan(in: input)
    default:
      return .permission(
        permission(
          toolName: toolName, input: input,
          workingDirectory: object["cwd"] as? String,
          alwaysAllow: alwaysAllow(in: object["permission_suggestions"]) ?? fallback(toolName)))
    }
  }

  static func permission(
    toolName: String,
    input: [String: Any],
    workingDirectory: String?,
    alwaysAllow: AgentAlwaysAllow?
  ) -> AgentToolPermission {
    let string = { (key: String) in input[key] as? String }
    let tool: AgentToolPermission.Tool
    var subject: String?
    var purpose = string("description")
    switch toolName {
    case "Bash", "shell", "exec_command":
      tool = .shell
      subject = string("command") ?? (input["command"] as? [String])?.joined(separator: " ")
    case "Edit", "MultiEdit":
      tool = .edit
      subject = string("file_path")
    case "NotebookEdit":
      tool = .edit
      subject = string("notebook_path")
    case "Write":
      tool = .write
      subject = string("file_path")
    case "Read":
      tool = .read
      subject = string("file_path")
    case "WebFetch":
      tool = .web
      subject = string("url")
    case "WebSearch":
      tool = .web
      subject = string("query")
    case "apply_patch":
      tool = .patch
      subject = string("command").map(patchedFiles)
    case "request_permissions":
      tool = .grant
      subject = requestedPermissions(input["permissions"])
      purpose = string("reason")
    case "write_stdin":
      tool = .terminalInput
      subject = string("chars")
    default:
      if toolName.hasPrefix("mcp__") {
        let parts = toolName.dropFirst(5).components(separatedBy: "__")
        tool = .mcp(server: parts.first ?? "", tool: parts.dropFirst().joined(separator: "__"))
      } else {
        tool = .other(toolName)
      }
    }
    return AgentToolPermission(
      tool: tool,
      toolName: toolName,
      subject: subject,
      purpose: purpose,
      details: details(of: input, toolName: toolName),
      workingDirectory: workingDirectory,
      alwaysAllow: alwaysAllow
    )
  }

  /// Everything the tool was handed, laid out for reading. A patch is shown as it is.
  static func details(of input: [String: Any], toolName: String) -> String? {
    if toolName == "apply_patch", let patch = input["command"] as? String { return patch }
    guard !input.isEmpty,
      let data = try? JSONSerialization.data(
        withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return nil }
    return String(decoding: data.prefix(detailsByteLimit), as: UTF8.self)
  }

  /// The files an `apply_patch` touches, one per line, as its headers name them.
  static func patchedFiles(_ patch: String) -> String {
    let prefixes = ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "]
    let files = patch.split(whereSeparator: \.isNewline).compactMap { line -> String? in
      guard let prefix = prefixes.first(where: { line.hasPrefix($0) }) else { return nil }
      return String(line.dropFirst(prefix.count))
    }
    return files.isEmpty ? patch : files.joined(separator: "\n")
  }

  /// What Codex's `request_permissions` asks for, in the words its dialog uses: `network; read
  /// a, b; write c; deny read d`. Its folders come as two lists, or as entries each with an access.
  static func requestedPermissions(_ permissions: Any?) -> String? {
    guard let permissions = permissions as? [String: Any] else { return nil }
    var parts: [String] = []
    if (permissions["network"] as? [String: Any])?["enabled"] as? Bool == true {
      parts.append("network")
    }
    let fileSystem = permissions["file_system"] as? [String: Any] ?? [:]
    var paths: [String: [String]] = [
      "read": fileSystem["read"] as? [String] ?? [], "write": fileSystem["write"] as? [String] ?? [],
    ]
    for entry in fileSystem["entries"] as? [[String: Any]] ?? [] {
      guard let access = entry["access"] as? String, let path = entry["path"] as? [String: Any]
      else { continue }
      let name: String?
      switch path["type"] as? String {
      case "path": name = path["path"] as? String
      case "glob_pattern": name = (path["pattern"] as? String).map { "glob \($0)" }
      case "special":
        let value = path["value"]
        name = (value as? String ?? (value as? [String: Any])?["kind"] as? String).map { ":\($0)" }
      default: name = nil
      }
      if let name { paths[access == "none" ? "deny" : access, default: []].append(name) }
    }
    for (access, label) in [("read", "read"), ("write", "write"), ("deny", "deny read")] {
      if let names = paths[access], !names.isEmpty {
        parts.append("\(label) \(names.joined(separator: ", "))")
      }
    }
    return parts.isEmpty ? nil : parts.joined(separator: "; ")
  }

  /// What Claude Code's "Yes, and always allow…" would allow: its `permission_suggestions`.
  static func alwaysAllow(in suggestions: Any?) -> AgentAlwaysAllow? {
    guard let suggestions = suggestions as? [[String: Any]], !suggestions.isEmpty else {
      return nil
    }
    var rules: [AgentAlwaysAllow.Rule] = []
    var scope = AgentAlwaysAllow.Scope.session
    for suggestion in suggestions {
      switch suggestion["type"] as? String {
      case "addDirectories":
        rules.append(.directories(suggestion["directories"] as? [String] ?? []))
      case "addRules", "replaceRules":
        for rule in suggestion["rules"] as? [[String: Any]] ?? [] {
          rules.append(
            .toolRule(
              tool: rule["toolName"] as? String ?? "", content: rule["ruleContent"] as? String))
        }
      case "setMode":
        rules.append(.mode(suggestion["mode"] as? String ?? ""))
      default:
        continue
      }
      switch suggestion["destination"] as? String {
      case "userSettings": scope = .user
      case "localSettings", "projectSettings": if scope == .session { scope = .project }
      default: break
      }
    }
    return rules.isEmpty ? nil : AgentAlwaysAllow(rules: rules, scope: scope)
  }

  static func questions(in input: [String: Any]) -> [AgentQuestion] {
    let questions = input["questions"] as? [[String: Any]] ?? []
    return questions.compactMap { question in
      guard let text = question["question"] as? String else { return nil }
      let options = (question["options"] as? [[String: Any]] ?? []).compactMap {
        option -> AgentQuestion.Option? in
        guard let label = option["label"] as? String else { return nil }
        return AgentQuestion.Option(
          label: label, description: option["description"] as? String,
          preview: preview(of: option))
      }
      let allowsMultipleChoices = question["multiSelect"] as? Bool ?? false
      // Claude Code draws previews beside the options, where no answer of one's own is offered.
      let showsPreviews = !allowsMultipleChoices && options.contains { $0.preview != nil }
      return AgentQuestion(
        header: question["header"] as? String,
        text: text,
        options: options,
        allowsMultipleChoices: allowsMultipleChoices,
        allowsFreeText: !showsPreviews
      )
    }
  }

  /// An option's preview, unless it is blank: Claude Code draws none for it.
  static func preview(of option: [String: Any]) -> String? {
    guard let preview = option["preview"] as? String,
      !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return preview
  }

  static func plan(in input: [String: Any]) -> AgentRequestContent {
    plan(input["plan"] as? String ?? "", isCut: false)
  }

  /// The plan's first lines; never complete when the report was cut inside it.
  static func plan(_ plan: String, isCut: Bool) -> AgentRequestContent {
    let lines = plan.split(separator: "\n", omittingEmptySubsequences: false)
    let excerpt = lines.prefix(planExcerptLineLimit).joined(separator: "\n")
    return .plan(excerpt: excerpt, isComplete: !isCut && lines.count <= planExcerptLineLimit)
  }
}

extension AgentActivityEvent {
  /// The request this report carries: read from its payload, known by the call it holds up.
  func requestNotice(
    isShown: Bool,
    alwaysAllow: (String) -> AgentAlwaysAllow? = { _ in nil }
  ) -> AgentRequestNotice {
    AgentRequestNotice(
      content: AgentRequestReading.content(of: self, alwaysAllow: alwaysAllow),
      reference: AgentRequestReading.reference(of: self),
      isShown: isShown
    )
  }
}
