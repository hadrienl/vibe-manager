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

  public var id: AgentRequestID { request.id }
}

/// The words and symbols of a request, the same in the palette, in VoiceOver and in a
/// notification.
public enum RequestPresentation {
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
    case .elicitation:
      return LocalizedStringResource(
        "Form to fill in", bundle: .module,
        comment: "The title of a request of an agent: a form an MCP server asks for.")
    case .unreadable:
      return LocalizedStringResource(
        "Permission", bundle: .module,
        comment: "The title of a request of an agent whose details could not be read.")
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
      case .mcp: return "puzzlepiece.extension"
      case .other: return "wrench.and.screwdriver"
      }
    case .questions: return "questionmark.bubble"
    case .plan: return "list.bullet.clipboard"
    case .elicitation: return "list.bullet.rectangle"
    case .unreadable: return "hand.raised"
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
    case .elicitation, .unreadable:
      return nil
    }
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
    parts.append(pending.request.receivedAt.formatted(.relative(presentation: .named)))
    var label = parts.joined(separator: ", ") + ". "
    label += String(localized: title(of: pending.request.content))
    if let subject = subject(of: pending.request.content) { label += ": " + subject }
    return label
  }
}

/// Text an agent wrote, made safe to show: nothing in it can hide what it says.
///
/// A control character, an escape sequence, a change of writing direction or a character of no
/// width can make a command read as another — `rm` passed off as `ls`. They are shown by name
/// instead of acting.
public enum DisplaySafeText {
  public static func visible(_ text: String) -> String {
    var result = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x0A, 0x09:
        result.append(scalar)
      case 0x1B:
        result.append(contentsOf: "␛".unicodeScalars)
      case 0x00...0x1F:
        // Control Pictures: U+2400 is NUL, and the others follow in order.
        result.append(Unicode.Scalar(0x2400 + scalar.value) ?? "?")
      case 0x7F:
        result.append(contentsOf: "␡".unicodeScalars)
      case 0x80...0x9F, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF:
        result.append(contentsOf: String(format: "⟨U+%04X⟩", scalar.value).unicodeScalars)
      default:
        result.append(scalar)
      }
    }
    return String(result)
  }
}
