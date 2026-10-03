import Foundation
import VibeApplication

/// How Claude Code reports what its agent does (#45): hooks passed with `--settings`.
///
/// `--settings` adds to the user's own settings rather than replacing them — their hooks keep
/// running beside these (checked against 2.1.282) — and nothing is written into
/// `~/.claude/settings.json`: a Claude Code started outside Vibe Manager is left exactly as it was.
public enum ClaudeCodeActivityHooks {
  /// What a background task finishing sends the agent in place of a user's message.
  static let synthesizedPromptMarker = #""prompt":"<task-notification>"#
  /// The only tools that stop to ask the user something. Hooking every tool would put a shell on
  /// the path of each command the agent runs, for nothing.
  static let questionTools = "AskUserQuestion|ExitPlanMode"

  struct Hook {
    let event: String
    let matcher: String?
    let payload: AgentActivityHookCommand.Payload
  }

  static let hooks: [Hook] = [
    Hook(event: "SessionStart", matcher: nil, payload: .keep),
    Hook(event: "UserPromptSubmit", matcher: nil, payload: .match(synthesizedPromptMarker)),
    Hook(event: "PreToolUse", matcher: questionTools, payload: .keep),
    Hook(event: "PermissionRequest", matcher: nil, payload: .keep),
    Hook(event: "Notification", matcher: nil, payload: .keep),
    // What the server asks, and the page it asks to open: never what its form is filled with.
    Hook(
      event: "Elicitation", matcher: nil,
      payload: .fields(["mcp_server_name", "message", "mode", "url"])),
    Hook(event: "ElicitationResult", matcher: nil, payload: .drop),
    // Which agent ran which tool on what: the request of #40 it settles, among several waiting.
    Hook(
      event: "PostToolUse", matcher: nil,
      payload: .fields(AgentRequestReading.resolutionFields)),
    Hook(
      event: "PostToolUseFailure", matcher: nil,
      payload: .fields(AgentRequestReading.resolutionFields)),
    Hook(
      event: "PermissionDenied", matcher: nil,
      payload: .fields(AgentRequestReading.resolutionFields)),
    // Every call of a batch resolved, refused ones included (#273): only which agent's batch.
    Hook(event: "PostToolBatch", matcher: nil, payload: .fields(["agent_id"])),
    Hook(event: "Stop", matcher: nil, payload: .drop),
    // Which error ended the turn, and the API's words for it (#273).
    Hook(
      event: "StopFailure", matcher: nil,
      payload: .fields(["error", "last_assistant_message"])),
    Hook(event: "SessionEnd", matcher: nil, payload: .drop),
  ]

  /// The JSON handed to `--settings`. Keys are sorted, so the same hooks always make the same
  /// command line.
  public static func settings() -> String {
    var events: [String: Any] = [:]
    for hook in hooks {
      var group: [String: Any] = [
        "hooks": [
          [
            "type": "command",
            "command": AgentActivityHookCommand.command(event: hook.event, payload: hook.payload),
            "timeout": AgentActivityHookCommand.timeoutSeconds,
          ]
        ]
      ]
      if let matcher = hook.matcher { group["matcher"] = matcher }
      events[hook.event] = [group]
    }
    let data = try? JSONSerialization.data(
      withJSONObject: ["hooks": events], options: [.sortedKeys, .withoutEscapingSlashes])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }
}

/// Reads the lines Claude Code's hooks write.
public struct ClaudeCodeSignalDecoder: AgentSignalDecoding {
  /// Enter takes the highlighted answer; a digit takes its option — "1. Yes", "2. Yes, and don't
  /// ask again", "3. No".
  public let approvalAnswerKeys: Set<[UInt8]> = Set([[0x0D]] + (0x31...0x39).map { [$0] })

  public var answerKeymap: (any AgentAnswerKeymap)? {
    ClaudeCodeAnswerKeymap()
  }

  /// The errors of `StopFailure` only the user can end: signing in again, an account to sort out.
  static let accountErrors: Set<String> = [
    "authentication_failed", "oauth_org_not_allowed", "account_on_hold", "billing_error",
    "cloud_credential_error",
  ]

  /// The notifications that say a dialog is up, checked against 2.1.285 and its documentation.
  /// `elicitation_dialog` is left out: the `Elicitation` hook reports the same dialog, and ends it.
  /// So is `worker_permission_prompt`: a teammate's permission, reported by its own hooks, which
  /// may come once it is answered.
  static let announcedKinds: [String: AgentTerminalPrompt.Kind] = [
    "permission_prompt": .permission,
    "elicitation_url_dialog": .form,
    "agent_needs_input": .other,
    "quota_auto_resume_stale": .other,
  ]

  private let makeInterruptionWatch: @Sendable (URL) -> AsyncStream<AgentSignal>

  public init(
    makeInterruptionWatch: @escaping @Sendable (URL) -> AsyncStream<AgentSignal> = {
      ClaudeCodeInterruptionWatch(transcript: $0).signals()
    }
  ) {
    self.makeInterruptionWatch = makeInterruptionWatch
  }

  public func signal(for event: AgentActivityEvent) -> AgentSignal? {
    switch event.name {
    case "SessionStart":
      return .channelConfirmed
    case "UserPromptSubmit":
      // The hook writes the marker back only when the prompt carries it.
      return .promptSubmitted(byUser: event.payload == nil)
    case "PreToolUse", "PermissionRequest":
      // `AskUserQuestion` also asks for permission to run: it is still a question. Any other
      // permission is an approval, even one whose tool cannot be read — the payload is cut short
      // past its byte limit, and a large `Write` leaves no JSON to read it from.
      let reference = AgentRequestReading.reference(of: event)
      let tool = event.string("tool_name") ?? reference.tool
      // `PreToolUse` comes before the dialog is drawn, `PermissionRequest` once it is (#40).
      let notice = event.requestNotice(isShown: event.name == "PermissionRequest")
      switch tool {
      case "AskUserQuestion": return .questionAsked(.question, tool: tool, notice: notice)
      case "ExitPlanMode": return .questionAsked(.approval, tool: tool, notice: notice)
      default:
        return event.name == "PermissionRequest"
          ? .questionAsked(.approval, tool: tool, notice: notice) : nil
      }
    case "Notification":
      let type = event.string("notification_type")
      if type == "idle_prompt" { return .waitingForInput }
      // Most of these repeat what `PermissionRequest` said, and may come once the user answered:
      // the machine lets them stand for a request only when no drawn one waits. Some dialogs have
      // no other report at all — a sandboxed command's network access above all (#273).
      guard var kind = Self.announcedKinds[type ?? ""] else { return nil }
      let message = event.string("message")
      if type == "permission_prompt" {
        // "A sandboxed command needs network access": the one permission with no report. Any
        // other repeats one, and may come once it is answered, as a request nothing ends.
        guard message?.localizedCaseInsensitiveContains("network") == true else { return nil }
        kind = .network
      }
      return .dialogAnnounced(AgentTerminalPrompt(kind: kind, message: message))
    case "Elicitation":
      return .questionAsked(
        .question,
        notice: AgentRequestNotice(
          content: .elicitation(Self.elicitation(in: event)),
          reference: AgentToolReference(tool: nil), isShown: true))
    case "ElicitationResult":
      return .questionResolved
    case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
      let reference = AgentRequestReading.reference(of: event)
      guard let tool = reference.tool else { return .questionResolved }
      return .toolFinished(tool, agentID: reference.agentID, subject: reference.subject)
    case "PostToolBatch":
      return .batchResolved(agentID: event.string("agent_id"))
    case "Stop":
      return .turnEnded
    case "StopFailure":
      guard let error = event.string("error"), Self.accountErrors.contains(error) else {
        return .turnEnded
      }
      return .turnFailed(
        AgentTerminalPrompt(kind: .account, message: event.string("last_assistant_message")))
    case "SessionEnd":
      return .agentEnded
    default:
      return nil
    }
  }

  /// The server's words, and the page it asks to open in URL mode — only then.
  static func elicitation(in event: AgentActivityEvent) -> AgentElicitation {
    AgentElicitation(
      server: event.string("mcp_server_name"),
      message: event.string("message"),
      url: event.string("mode") == "url" ? event.string("url").flatMap(URL.init(string:)) : nil)
  }

  /// Claude Code reports no interruption through its hooks — neither Escape during a turn nor a
  /// permission refused with it — but writes one into the transcript its `SessionStart` names.
  public func additionalSignals(after event: AgentActivityEvent) -> AsyncStream<AgentSignal>? {
    guard event.name == "SessionStart", let path = event.string("transcript_path"),
      path.hasPrefix("/")
    else { return nil }
    return makeInterruptionWatch(URL(fileURLWithPath: path))
  }
}

/// Follows a Claude Code transcript for the line an interruption leaves in it.
///
/// That line is the CLI's own convention, not an interface: a `user` message whose text is exactly
/// `[Request interrupted by user]`, or `… for tool use]` when a tool was stopped or refused. Only
/// that shape counts — a tool's output that happens to quote the words is not an interruption.
public struct ClaudeCodeInterruptionWatch: Sendable {
  static let markers: Set<String> = [
    "[Request interrupted by user]", "[Request interrupted by user for tool use]",
  ]

  static let needle = Data("[Request interrupted by user".utf8)

  private let transcript: URL
  private let onWatching: (@Sendable (AppendedLines.Watching) -> Void)?

  public init(transcript: URL) {
    self.init(transcript: transcript, onWatching: nil)
  }

  init(transcript: URL, onWatching: (@Sendable (AppendedLines.Watching) -> Void)?) {
    self.transcript = transcript
    self.onWatching = onWatching
  }

  /// Interruptions written from now on; what the transcript already holds belongs to the past.
  public func signals() -> AsyncStream<AgentSignal> {
    var appended = AppendedLines(file: transcript, start: .end, needles: [Self.needle])
    appended.onWatching = onWatching
    let lines = appended.lines()
    return AsyncStream { continuation in
      let task = Task {
        for await line in lines where Self.isInterruption(line) {
          continuation.yield(.interrupted)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  static func isInterruption(_ line: Data) -> Bool {
    // Most lines are tool calls and their output, some of them large: the words are looked for
    // before any JSON is decoded.
    guard LineSplitter.contains(line, anyOf: [needle]),
      let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
      object["type"] as? String == "user",
      let message = object["message"] as? [String: Any]
    else { return false }
    if let text = message["content"] as? String { return markers.contains(text) }
    guard let blocks = message["content"] as? [[String: Any]] else { return false }
    return blocks.contains { block in
      block["type"] as? String == "text" && (block["text"] as? String).map(markers.contains) == true
    }
  }

}

extension ClaudeCodeAgentProvider: AgentActivityReporting {
  public func reportingActivity(_ plan: AgentLaunchPlan, to log: URL) -> AgentLaunchPlan {
    plan.reportingActivity(options: ["--settings", ClaudeCodeActivityHooks.settings()], to: log)
  }

  public func activityDecoder() -> any AgentSignalDecoding {
    ClaudeCodeSignalDecoder()
  }
}
