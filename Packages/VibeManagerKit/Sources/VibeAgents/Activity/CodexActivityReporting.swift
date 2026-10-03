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
    var timeout = AgentActivityHookCommand.timeoutSeconds
  }

  /// The most Codex gives the hooks of `Interrupt` and `SessionEnd`, which run as it stops: a
  /// longer timeout is cut to it with a warning on screen (0.159.2, `hooks/src/engine/discovery.rs`).
  /// Its approval is kept by the cut timeout, so asking for this one changes nothing to it.
  static let stoppingTimeoutSeconds = 3

  /// Checked against `codex-cli 0.156.1`, which also knows `Interrupt` — the one signal Claude
  /// Code does not give.
  ///
  /// `SessionStart` keeps its `session_id` (#144): Codex creates its session at launch but names
  /// it nowhere until the first message, when the rollout and this hook appear together (checked
  /// with 0.157.1). Written into this session's own log, it tells which rollout is whose even when
  /// two panes work in the same folder.
  static let hooks: [Hook] = [
    Hook(event: "SessionStart", payload: .fields(["session_id"])),
    Hook(event: "UserPromptSubmit", payload: .drop),
    Hook(event: "PermissionRequest", payload: .keep),
    // Which agent ran which tool on what (#273): the request it settles, among several waiting.
    Hook(event: "PostToolUse", payload: .fields(AgentRequestReading.resolutionFields)),
    Hook(event: "Stop", payload: .drop),
    Hook(event: "Interrupt", payload: .drop, timeout: stoppingTimeoutSeconds),
    Hook(event: "SessionEnd", payload: .drop, timeout: stoppingTimeoutSeconds),
  ]

  /// Every command the hooks run, as Codex lists them back.
  public static var commands: [String] {
    hooks.map { AgentActivityHookCommand.command(event: $0.event, payload: $0.payload) }
  }

  /// Codex writes a notification to its terminal, as OSC 9, when it draws a dialog (#273): the
  /// only word of the dialogs no hook reports — an MCP server's form, "Implement this plan?" — and
  /// the one sign that a permission its hook reported is on screen, not settled by its automatic
  /// review. Settings, not hooks: nothing for the user to approve. The end of a turn is left out,
  /// the application tells it from `Stop`.
  static let notificationOptions = [
    "-c", #"tui.notifications=["approval-requested","plan-mode-prompt","async-question"]"#,
    "-c", #"tui.notification_method="osc9""#,
    "-c", #"tui.notification_condition="always""#,
  ]

  /// The `-c` options, one per event.
  public static func options() -> [String] {
    hooks.flatMap { hook -> [String] in
      let command = AgentActivityHookCommand.command(event: hook.event, payload: hook.payload)
      return [
        "-c",
        #"hooks.\#(hook.event)=[{hooks=[{type="command",timeout=\#(hook.timeout),command=\#(tomlString(command))}]}]"#,
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
  public let approvalAnswerKeys: Set<[UInt8]> = [[0x79], [0x61], [0x70], [0x6E], [0x0D]]

  /// Follows the session's rollout for the questions no hook reports (#40); `nil` without one.
  private let questions: (@Sendable (Date) -> AsyncStream<AgentSignal>)?

  public init(questions: (@Sendable (Date) -> AsyncStream<AgentSignal>)? = nil) {
    self.questions = questions
  }

  public var answerKeymap: (any AgentAnswerKeymap)? {
    CodexAnswerKeymap()
  }

  /// The session `SessionStart` names: the one this process holds from now on. Codex starts
  /// another one when the user asks for a new conversation, and its hook names that one too.
  public func conversationIdentifier(in event: AgentActivityEvent) -> String? {
    guard event.name == "SessionStart", let identifier = event.string("session_id"),
      UUID(uuidString: identifier) != nil
    else { return nil }
    return identifier
  }

  public func signal(for event: AgentActivityEvent) -> AgentSignal? {
    switch event.name {
    case "SessionStart": return .channelConfirmed
    case "UserPromptSubmit": return .promptSubmitted(byUser: true)
    case "PermissionRequest":
      // Codex runs the hook before its automatic review, which may settle the permission with no
      // dialog ever drawn (0.159, `core/src/tools/approvals.rs`): drawn once Codex says so.
      return .questionAsked(
        .approval,
        notice: Self.withoutAlwaysForHosts(
          event.requestNotice(isShown: false, alwaysAllow: CodexAnswerKeymap.alwaysAllow)))
    case "PostToolUse":
      let reference = AgentRequestReading.reference(of: event)
      // An asynchronous question's tool ends at once, its question still waiting: the rollout
      // says when Codex takes it away (#273).
      guard reference.tool != CodexQuestionWatch.asyncTool else { return nil }
      guard let tool = reference.tool else { return .questionResolved }
      return .toolFinished(tool, agentID: reference.agentID, subject: reference.subject)
    case "Stop": return .turnEnded
    case "Interrupt": return .interrupted
    case "SessionEnd": return .agentEnded
    default: return nil
    }
  }

  public var readsTerminalNotifications: Bool {
    true
  }

  /// A network access comes as a `Bash` permission whose description is `network-access <host>`
  /// (0.159, `core/src/tools/approvals.rs`). Its dialog allows the host for the conversation, or
  /// for good — never commands that start the same way, which "always" says for a command: the
  /// answer is given once, or in the terminal.
  static func withoutAlwaysForHosts(_ notice: AgentRequestNotice) -> AgentRequestNotice {
    guard case .permission(let permission) = notice.content,
      permission.purpose?.hasPrefix("network-access ") == true
    else { return notice }
    return AgentRequestNotice(
      content: .permission(
        AgentToolPermission(
          tool: permission.tool, toolName: permission.toolName, subject: permission.subject,
          purpose: permission.purpose, details: permission.details,
          workingDirectory: permission.workingDirectory, alwaysAllow: nil,
          isComplete: permission.isComplete)),
      reference: notice.reference, isShown: notice.isShown, key: notice.key)
  }

  /// The start of a command as its report gives it, out of the notification that quotes it: the
  /// command Codex runs — `/bin/zsh -lc 'touch a…` — cut at thirty characters.
  static func commandStart(quoted: String) -> String {
    quotedCommand(quoted).text
  }

  /// The command out of the notification that quotes it, and whether it was cut short: a command
  /// quoted whole names one request, not every one that starts the same way (#280).
  static func quotedCommand(_ quoted: String) -> (text: String, isCut: Bool) {
    var text = Substring(quoted)
    let isCut = text.hasSuffix("...") || text.hasSuffix("…")
    if text.hasSuffix("...") {
      text = text.dropLast(3)
    } else if text.hasSuffix("…") {
      text = text.dropLast()
    }
    // The shell Codex wraps the model's command in, and the quote around it.
    if let wrapper = text.range(of: #"^\S*sh -l?c ['"]?"#, options: .regularExpression) {
      let quote = text[wrapper].last.flatMap { "'\"".contains($0) ? $0 : nil }
      text = text[wrapper.upperBound...]
      if !isCut, let quote, text.last == quote { text = text.dropLast() }
    }
    return (String(text), isCut)
  }

  /// Codex's notifications, as `tui/src/chatwidget/notifications.rs` words them in 0.159.
  public func signal(forTerminalNotification message: String) -> AgentSignal? {
    func announced(_ kind: AgentTerminalPrompt.Kind) -> AgentSignal {
      .dialogAnnounced(AgentTerminalPrompt(kind: kind, message: message))
    }
    // The form of an MCP tool's permission, or a server's own request, which has no report.
    if let server = message.trimmingPrefix("Approval requested by ") {
      return .dialogDrawn(
        AgentDrawnDialog(.server(server)),
        otherwise: AgentTerminalPrompt(kind: .form, message: message))
    }
    if let command = message.trimmingPrefix("Approval requested: ") {
      let quoted = Self.quotedCommand(command)
      return .dialogDrawn(
        AgentDrawnDialog(quoted.isCut ? .commandStart(quoted.text) : .command(quoted.text)))
    }
    if let edited = message.trimmingPrefix("Codex wants to edit ") {
      let isSeveral = edited.hasSuffix(" files") && Int(edited.dropLast(" files".count)) != nil
      return .dialogDrawn(AgentDrawnDialog(isSeveral ? .files : .file(edited)))
    }
    if let title = message.trimmingPrefix("Plan mode prompt: ") {
      switch title {
      case "Implement this plan?": return announced(.plan)
      // A choice the user opened themselves, in the terminal they are looking at.
      case "Apply reasoning change": return nil
      // The questions of `request_user_input`, also read from the rollout.
      default: return announced(.question)
      }
    }
    if message.hasPrefix("Question: ") { return announced(.question) }
    return nil
  }

  /// Codex's `request_user_input` has no hook of its own: its questions are read from the rollout
  /// the session writes, found once the session has started.
  public func additionalSignals(after event: AgentActivityEvent) -> AsyncStream<AgentSignal>? {
    guard event.name == "SessionStart", let questions else { return nil }
    return questions(event.date)
  }
}

extension String {
  /// The rest of the string after `prefix`, or `nil` when it does not start with it.
  fileprivate func trimmingPrefix(_ prefix: String) -> String? {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
  }
}

extension CodexAgentProvider: AgentActivityReporting {
  public func reportingActivity(_ plan: AgentLaunchPlan, to log: URL) -> AgentLaunchPlan {
    plan.reportingActivity(
      options: CodexActivityHooks.options() + CodexActivityHooks.notificationOptions, to: log)
  }

  public func activityDecoder() -> any AgentSignalDecoding {
    CodexSignalDecoder()
  }

  public func activityDecoder(workingDirectoryPath: String?, environment: [String: String])
    -> any AgentSignalDecoding
  {
    guard let workingDirectoryPath else { return CodexSignalDecoder() }
    let sessions = CodexHome.sessionsDirectory(
      environment: ProcessInfo.processInfo.environment.merging(environment) { $1 })
    return CodexSignalDecoder { since in
      CodexQuestionWatch(
        sessionsDirectory: sessions, workingDirectoryPath: workingDirectoryPath, since: since
      ).signals()
    }
  }
}
