import Foundation
import VibeApplication
import VibeDomain

/// A request waiting in a session that is not in front of the user, with what the palette needs
/// to say whose it is without opening it (#40).
public struct PendingRequest: Identifiable, Equatable {
  public let request: AgentRequest
  public let session: WorkSession
  public let answering: AgentRequestAnswering
  /// Its place in its session's queue, and how many wait there.
  public let position: Int
  public let queueCount: Int
  public let agentName: String?
  /// The folder the session works in, by its last component.
  public let folderName: String?
  public let folderPath: String?
  public let branch: String?
  /// What the sub-agent that asked was started for, when its conversation shows it (#180).
  public var subagentDescription: String? = nil

  public var id: AgentRequestID { request.id }

  /// Asked by one of the agent's sub-agents rather than by the agent itself.
  public var isFromSubagent: Bool { request.reference.agentID != nil }
}

/// The words and symbols of a request, the same in the palette, in VoiceOver and in a
/// notification.
public enum RequestPresentation {
  /// Which sub-agent asked, when one did rather than the agent (#180).
  public static func subagentLine(for pending: PendingRequest) -> LocalizedStringResource? {
    guard pending.isFromSubagent else { return nil }
    guard let description = pending.subagentDescription else {
      return LocalizedStringResource(
        "Asked by a sub-agent", bundle: .module,
        comment: "On a request's card: one of the agent's sub-agents asks, not the agent itself.")
    }
    return LocalizedStringResource(
      "Asked by the sub-agent “\(description)”", bundle: .module,
      comment: "On a request's card: which of the agent's sub-agents asks.")
  }

  public static func title(of content: AgentRequestContent) -> LocalizedStringResource {
    switch content {
    case .permission(let permission): return toolTitle(permission.tool)
    case .questions(let questions):
      return questions.count > 1
        ? LocalizedStringResource(
          "\(questions.count) questions", bundle: .module,
          comment: "The title of a request of an agent: several questions at once.")
        : LocalizedStringResource(
          "Question", bundle: .module, comment: "The title of a request of an agent.")
    case .plan:
      return LocalizedStringResource(
        "Plan to approve", bundle: .module, comment: "The title of a request of an agent.")
    case .elicitation(let elicitation) where elicitation.url != nil:
      return LocalizedStringResource(
        "Page to open", bundle: .module,
        comment: "The title of a request of an agent: an MCP server asks the user to open a page.")
    case .elicitation:
      return LocalizedStringResource(
        "Form to fill in", bundle: .module,
        comment: "The title of a request of an agent: a form an MCP server asks for.")
    case .unreadable:
      return LocalizedStringResource(
        "Permission", bundle: .module,
        comment: "The title of a request of an agent whose details could not be read.")
    case .inTerminal(let prompt):
      return promptTitle(prompt.kind)
    }
  }

  /// A dialog only announced by the CLI (#273), by what it is about.
  static func promptTitle(_ kind: AgentTerminalPrompt.Kind) -> LocalizedStringResource {
    switch kind {
    case .network:
      return LocalizedStringResource(
        "Network access", bundle: .module,
        comment: "The title of a request of an agent: a command wants to reach the network.")
    case .permission:
      return LocalizedStringResource(
        "Permission", bundle: .module,
        comment: "The title of a request of an agent whose details could not be read.")
    case .form:
      return LocalizedStringResource(
        "Form to fill in", bundle: .module,
        comment: "The title of a request of an agent: a form an MCP server asks for.")
    case .question:
      return LocalizedStringResource(
        "Question", bundle: .module, comment: "The title of a request of an agent.")
    case .plan:
      return LocalizedStringResource(
        "Plan to approve", bundle: .module, comment: "The title of a request of an agent.")
    case .account:
      return LocalizedStringResource(
        "Account to check", bundle: .module,
        comment:
          "The title of a request of an agent: its CLI is signed out, refused or unpaid, and the turn stopped."
      )
    case .startup:
      return LocalizedStringResource(
        "Startup dialog", bundle: .module,
        comment:
          "The title of a request of an agent: a dialog of the CLI's start — trusting the folder, approving servers, signing in — is most likely waiting."
      )
    case .other:
      return LocalizedStringResource(
        "Waiting in the terminal", bundle: .module,
        comment: "The title of a request of an agent: a dialog of its terminal, of no known kind.")
    }
  }

  public static func toolTitle(_ tool: AgentToolPermission.Tool) -> LocalizedStringResource {
    switch tool {
    case .shell:
      return LocalizedStringResource(
        "Shell command", bundle: .module, comment: "A permission an agent asks for: its tool.")
    case .edit:
      return LocalizedStringResource(
        "File edit", bundle: .module, comment: "A permission an agent asks for: its tool.")
    case .write:
      return LocalizedStringResource(
        "File write", bundle: .module, comment: "A permission an agent asks for: its tool.")
    case .read:
      return LocalizedStringResource(
        "File read", bundle: .module, comment: "A permission an agent asks for: its tool.")
    case .web:
      return LocalizedStringResource(
        "Web access", bundle: .module, comment: "A permission an agent asks for: its tool.")
    case .patch:
      return LocalizedStringResource(
        "File changes", bundle: .module,
        comment: "A permission an agent asks for: a patch to apply to files.")
    case .grant:
      return LocalizedStringResource(
        "More permissions", bundle: .module,
        comment:
          "A permission an agent asks for: more than its sandbox allows, the network or folders.")
    case .terminalInput:
      return LocalizedStringResource(
        "Terminal input", bundle: .module,
        comment: "A permission an agent asks for: to type into a terminal it left running.")
    case .mcp:
      return LocalizedStringResource(
        "MCP tool", bundle: .module, comment: "A permission an agent asks for: its tool.")
    case .other:
      return LocalizedStringResource(
        "Tool", bundle: .module, comment: "A permission an agent asks for: a tool of another kind.")
    }
  }

  public static func symbolName(of content: AgentRequestContent) -> String {
    switch content {
    case .permission(let permission):
      switch permission.tool {
      case .shell: return "terminal"
      case .edit: return "pencil"
      case .write: return "doc.badge.plus"
      case .read: return "doc.text"
      case .web: return "globe"
      case .patch: return "doc.on.doc"
      case .grant: return "lock.open"
      case .terminalInput: return "keyboard"
      case .mcp: return "puzzlepiece.extension"
      case .other: return "wrench.and.screwdriver"
      }
    case .questions: return "questionmark.bubble"
    case .plan: return "list.bullet.clipboard"
    case .elicitation(let elicitation):
      return elicitation.url != nil ? "link" : "list.bullet.rectangle"
    case .unreadable: return "hand.raised"
    case .inTerminal(let prompt):
      switch prompt.kind {
      case .network: return "network"
      case .permission: return "hand.raised"
      case .form: return "list.bullet.rectangle"
      case .question: return "questionmark.bubble"
      case .plan: return "list.bullet.clipboard"
      case .account: return "person.crop.circle.badge.exclamationmark"
      case .startup: return "power"
      case .other: return "terminal"
      }
    }
  }

  /// What the tool works on, as the agent wrote it — never trusted, so made safe to show.
  public static func subject(of content: AgentRequestContent) -> String? {
    switch content {
    case .permission(let permission):
      if case .mcp(let server, let tool) = permission.tool, permission.subject == nil {
        return "\(server) · \(tool)"
      }
      return permission.subject.map(DisplaySafeText.visible)
    case .questions(let questions):
      return questions.first.map { DisplaySafeText.visible($0.text) }
    case .plan(let excerpt, _):
      return excerpt.split(separator: "\n").first.map { DisplaySafeText.visible(String($0)) }
    case .inTerminal(let prompt):
      return prompt.message.map(DisplaySafeText.visible)
    case .elicitation(let elicitation):
      return elicitation.message.map(DisplaySafeText.visible)
    case .unreadable:
      return nil
    }
  }

  /// Which MCP server asks, on the card of its form or page.
  public static func serverLine(_ server: String) -> LocalizedStringResource {
    LocalizedStringResource(
      "Asked by the MCP server “\(server)”", bundle: .module,
      comment: "On a request's card: the MCP server that asks the user for a form or a page.")
  }

  /// What "always allow" allows, in words: its rules and how long they last.
  public static func alwaysAllowTitle(_ allow: AgentAlwaysAllow) -> LocalizedStringResource {
    let rules = allow.rules.map(ruleDescription).joined(separator: ", ")
    switch allow.scope {
    case .session:
      return LocalizedStringResource(
        "Always allow \(rules) for this session", bundle: .module,
        comment: "A button answering an agent's permission. The argument lists what is allowed.")
    case .project:
      return LocalizedStringResource(
        "Always allow \(rules) in this project", bundle: .module,
        comment: "A button answering an agent's permission. The argument lists what is allowed.")
    case .user:
      return LocalizedStringResource(
        "Always allow \(rules) everywhere", bundle: .module,
        comment: "A button answering an agent's permission. The argument lists what is allowed.")
    }
  }

  static func ruleDescription(_ rule: AgentAlwaysAllow.Rule) -> String {
    switch rule {
    case .directories(let folders):
      let names = folders.map { URL(fileURLWithPath: $0).lastPathComponent }
      return String(
        localized: LocalizedStringResource(
          "access to \(names.joined(separator: ", "))", bundle: .module,
          comment: "What always allowing grants: access to these folders."))
    case .toolRule(let tool, let content):
      return DisplaySafeText.visible(content.map { "\(tool)(\($0))" } ?? tool)
    case .mode(let mode):
      return mode == "acceptEdits"
        ? String(
          localized: LocalizedStringResource(
            "file edits", bundle: .module,
            comment: "What always allowing grants: the agent's file edits, accepted as they come."))
        : DisplaySafeText.visible(mode)
    case .commandPrefix:
      return String(
        localized: LocalizedStringResource(
          "commands starting the same way", bundle: .module,
          comment: "What always allowing grants: commands with the same beginning."))
    case .files:
      return String(
        localized: LocalizedStringResource(
          "changes to these files", bundle: .module,
          comment: "What always allowing grants: further changes to the same files."))
    case .permissions:
      return String(
        localized: LocalizedStringResource(
          "these permissions", bundle: .module,
          comment: "What always allowing grants: the permissions the agent asked for."))
    }
  }

  /// Why the request is answered in its terminal only, in one line.
  public static func terminalReason(_ reason: AgentRequestTerminalReason, isQuestion: Bool)
    -> LocalizedStringResource
  {
    switch reason {
    case .notYetShown:
      return isQuestion
        ? LocalizedStringResource(
          "Answer this question in the session.", bundle: .module,
          comment:
            "Why a request is answered in its terminal: its CLI never says when its dialog is shown."
        )
        : LocalizedStringResource(
          "Waiting for the agent to show its dialog…", bundle: .module,
          comment: "Why a request cannot be answered yet: its dialog is not on screen yet.")
    case .queued:
      return LocalizedStringResource(
        "After the previous request of this session.", bundle: .module,
        comment: "Why a request cannot be answered yet: another request of its session comes first."
      )
    case .uncertain:
      return LocalizedStringResource(
        "Several requests are waiting in this session: answer in the session.", bundle: .module,
        comment:
          "Why a request is answered in its terminal: which of them is on screen is not known.")
    case .truncated:
      return LocalizedStringResource(
        "Too long to be shown in full: allow it in the session.", bundle: .module,
        comment: "Why a permission cannot be granted from the palette: it was cut short.")
    case .notSupported:
      return LocalizedStringResource(
        "This agent's dialog can only be answered in the session.", bundle: .module,
        comment:
          "Why a request is answered in its terminal: its CLI cannot be answered from outside.")
    }
  }

  /// What a notification says of the request, by the user's choice.
  public static func notificationBody(
    of content: AgentRequestContent, detail: RequestNotificationContent
  ) -> String {
    let title = String(localized: title(of: content))
    guard detail == .detail, let subject = subject(of: content) else {
      switch content {
      case .permission, .unreadable:
        return String(
          localized: LocalizedStringResource(
            "Permission requested: \(title)", bundle: .module,
            comment: "The body of a notification. The argument is the kind of tool."))
      default:
        return title
      }
    }
    return "\(title) — \(subject)"
  }

  /// The whole card, for VoiceOver: whose it is, then what it asks.
  public static func accessibilityLabel(for pending: PendingRequest, now: Date = Date()) -> String {
    var parts = [pending.session.name]
    if let agent = pending.agentName { parts.append(agent) }
    if let folder = pending.folderName { parts.append(folder) }
    if let branch = pending.branch {
      parts.append(
        String(
          localized: LocalizedStringResource(
            "branch \(branch)", bundle: .module, comment: "Said by VoiceOver on a request's card."))
      )
    }
    if let subagent = subagentLine(for: pending) { parts.append(String(localized: subagent)) }
    parts.append(pending.request.receivedAt.formatted(.relative(presentation: .named)))
    var label = parts.joined(separator: ", ") + ". "
    label += String(localized: title(of: pending.request.content))
    if let subject = subject(of: pending.request.content) { label += ": " + subject }
    return label
  }
}
