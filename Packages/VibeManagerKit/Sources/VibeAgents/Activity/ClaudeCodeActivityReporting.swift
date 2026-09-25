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
    Hook(event: "Elicitation", matcher: nil, payload: .drop),
    Hook(event: "ElicitationResult", matcher: nil, payload: .drop),
    Hook(event: "PostToolUse", matcher: nil, payload: .drop),
    Hook(event: "PostToolUseFailure", matcher: nil, payload: .drop),
    Hook(event: "PermissionDenied", matcher: nil, payload: .drop),
    Hook(event: "Stop", matcher: nil, payload: .drop),
    Hook(event: "StopFailure", matcher: nil, payload: .drop),
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
      // `AskUserQuestion` also asks for permission to run: it is still a question.
      switch event.string("tool_name") {
      case "AskUserQuestion": return .questionAsked(.question)
      case "ExitPlanMode": return .questionAsked(.approval)
      case .some where event.name == "PermissionRequest": return .questionAsked(.approval)
      default: return nil
      }
    case "Notification":
      // Only the idle reminder is read. `permission_prompt` and `elicitation_dialog` repeat what
      // `PermissionRequest` and `Elicitation` already said, and may arrive once the user has
      // answered — putting back a question that is gone.
      return event.string("notification_type") == "idle_prompt" ? .waitingForInput : nil
    case "Elicitation":
      return .questionAsked(.question)
    case "ElicitationResult", "PostToolUse", "PostToolUseFailure", "PermissionDenied":
      return .questionResolved
    case "Stop", "StopFailure":
      return .turnEnded
    case "SessionEnd":
      return .agentEnded
    default:
      return nil
    }
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

  private let transcript: URL
  private let pollInterval: Duration

  public init(transcript: URL, pollInterval: Duration = .milliseconds(500)) {
    self.transcript = transcript
    self.pollInterval = pollInterval
  }

  /// Interruptions written from now on; what the transcript already holds belongs to the past.
  public func signals() -> AsyncStream<AgentSignal> {
    let transcript = transcript
    let pollInterval = pollInterval
    return AsyncStream { continuation in
      let task = Task {
        var offset = Self.size(of: transcript)
        var pending = Data()
        while !Task.isCancelled {
          if let handle = try? FileHandle(forReadingFrom: transcript) {
            defer { try? handle.close() }
            let size = Self.size(of: transcript)
            // Smaller than what was read: the file was replaced, and is read again from the start.
            if size < offset {
              offset = 0
              pending = Data()
            }
            if size > offset, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - offset))
            {
              offset += UInt64(data.count)
              pending.append(data)
              while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<newline])
                pending = Data(pending[(newline + 1)...])
                if Self.isInterruption(line) { continuation.yield(.interrupted) }
              }
            }
          }
          try? await Task.sleep(for: pollInterval)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  static func isInterruption(_ line: Data) -> Bool {
    // Most lines are tool calls and their output, some of them large: the words are looked for
    // before any JSON is decoded.
    guard line.range(of: Data("[Request interrupted by user".utf8)) != nil,
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

  private static func size(of url: URL) -> UInt64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
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
