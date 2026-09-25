import Foundation
import VibeApplication

/// How Codex reports what its agent does (#45): hooks passed as `-c hooks.<Event>=[…]`.
///
/// Not `notify`: it holds a single program, and replacing the user's would break whatever they
/// wired to it. Codex asks the user to approve a hook before running it and remembers the approval
/// by the hook's fingerprint, so these commands never change unless on purpose (`CodexHookTrust`).
public enum CodexActivityHooks {
  struct Hook {
    let event: String
    let payload: AgentActivityHookCommand.Payload
  }

  /// Checked against `codex-cli 0.156.1`, which also knows `Interrupt` — the one signal Claude
  /// Code does not give.
  static let hooks: [Hook] = [
    Hook(event: "SessionStart", payload: .drop),
    Hook(event: "UserPromptSubmit", payload: .drop),
    Hook(event: "PermissionRequest", payload: .keep),
    Hook(event: "PostToolUse", payload: .drop),
    Hook(event: "Stop", payload: .drop),
    Hook(event: "Interrupt", payload: .drop),
    Hook(event: "SessionEnd", payload: .drop),
  ]

  /// Every command the hooks run, as Codex lists them back.
  public static var commands: [String] {
    hooks.map { AgentActivityHookCommand.command(event: $0.event, payload: $0.payload) }
  }

  /// The `-c` options, one per event.
  public static func options() -> [String] {
    hooks.flatMap { hook -> [String] in
      let command = AgentActivityHookCommand.command(event: hook.event, payload: hook.payload)
      return [
        "-c",
        #"hooks.\#(hook.event)=[{hooks=[{type="command",timeout=\#(AgentActivityHookCommand.timeoutSeconds),command=\#(tomlString(command))}]}]"#,
      ]
    }
  }

  /// A TOML basic string. JSON's escaping is a subset TOML reads the same way.
  static func tomlString(_ value: String) -> String {
    let data = try? JSONSerialization.data(
      withJSONObject: [value], options: [.withoutEscapingSlashes])
    guard let data, let array = String(data: data, encoding: .utf8) else { return "\"\"" }
    return String(array.dropFirst().dropLast())
  }

  /// The `-c` values a plan carries for these hooks, and only those.
  static func hookOptions(in arguments: [String]) -> [String] {
    var options: [String] = []
    var index = arguments.startIndex
    while index < arguments.endIndex, arguments[index] != "--" {
      if arguments[index] == "-c", arguments.index(after: index) < arguments.endIndex {
        let value = arguments[arguments.index(after: index)]
        if value.hasPrefix("hooks.") { options += ["-c", value] }
        index = arguments.index(index, offsetBy: 2)
      } else {
        index = arguments.index(after: index)
      }
    }
    return options
  }
}

/// Reads the lines Codex's hooks write.
public struct CodexSignalDecoder: AgentSignalDecoding {
  /// `y` approves, `a` approves for the rest of the session, `n` refuses, Enter takes the
  /// highlighted choice.
  public let approvalAnswerKeys: Set<[UInt8]> = [[0x79], [0x61], [0x6E], [0x0D]]

  public init() {}

  public func signal(for event: AgentActivityEvent) -> AgentSignal? {
    switch event.name {
    case "SessionStart": return .channelConfirmed
    case "UserPromptSubmit": return .promptSubmitted(byUser: true)
    case "PermissionRequest": return .questionAsked(.approval)
    case "PostToolUse": return .questionResolved
    case "Stop": return .turnEnded
    case "Interrupt": return .interrupted
    case "SessionEnd": return .agentEnded
    default: return nil
    }
  }
}

extension CodexAgentProvider: AgentActivityReporting {
  public func reportingActivity(_ plan: AgentLaunchPlan, to log: URL) -> AgentLaunchPlan {
    plan.reportingActivity(options: CodexActivityHooks.options(), to: log)
  }

  public func activityDecoder() -> any AgentSignalDecoding {
    CodexSignalDecoder()
  }
}
