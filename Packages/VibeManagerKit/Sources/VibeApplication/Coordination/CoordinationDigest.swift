import Foundation
import VibeDomain

/// What a coordinator reads of its children (#352): their requests and conversations, as bounded
/// text. Pure. Everything here came from a child's agent — and through it from whatever it read —
/// so its control characters are named, never passed on.
public enum CoordinationDigest {
  /// The longest a request is told.
  static let requestLimit = 400
  /// The longest one entry of a conversation is told.
  static let entryLimit = 1_500
  public static let readLimit = 12_000
  public static let defaultEntryCount = 20
  public static let maximumEntryCount = 100

  /// What a child waits for, in a line.
  public static func summary(of request: AgentRequest) -> String {
    let text: String
    switch request.content {
    case .permission(let permission):
      let subject = permission.subject.map { ": \($0)" } ?? ""
      text = "permission to use \(permission.toolName)\(subject)"
    case .questions(let questions):
      let asked = questions.map(\.text).joined(separator: " / ")
      text =
        questions.count == 1 ? "a question: \(asked)" : "\(questions.count) questions: \(asked)"
    case .plan(let excerpt, _):
      text = "approval of its plan: \(excerpt)"
    case .elicitation:
      text = "a form of an MCP server, to fill in in its terminal"
    case .unreadable(let tool):
      text = "a permission\(tool.map { " for \($0)" } ?? "") that only its terminal shows"
    case .inTerminal:
      text = "an answer in its terminal"
    }
    return cut(DisplaySafeText.visible(oneLine(text)), to: requestLimit)
  }

  /// The last `count` entries of a conversation, one paragraph each, the whole cut at `limit`
  /// characters from its start: the most recent entries are the ones kept.
  public static func transcript(
    _ entries: [ConversationEntry], last count: Int = defaultEntryCount, limit: Int = readLimit
  ) -> String {
    let count = min(max(count, 1), maximumEntryCount)
    var paragraphs: [String] = []
    var total = 0
    for entry in entries.suffix(count).reversed() {
      guard let line = line(for: entry) else { continue }
      let text = cut(DisplaySafeText.visible(line), to: entryLimit)
      guard total + text.count + 2 <= limit else { break }
      total += text.count + 2
      paragraphs.append(text)
    }
    return paragraphs.reversed().joined(separator: "\n\n")
  }

  static func line(for entry: ConversationEntry) -> String? {
    switch entry.content {
    case .userPrompt(let text, _):
      return "User: \(text)"
    case .agentText(let text):
      return "Agent: \(text)"
    case .reasoning:
      return nil
    case .tool(let call):
      let parameter = call.parameters.first.map { " \(oneLine($0.value))" } ?? ""
      let title = call.summary.map(oneLine) ?? "\(call.kind.family)\(parameter)"
      return "Tool (\(state(of: call.state))): \(title)"
    case .notice(let notice):
      switch notice {
      case .interrupted: return "The user stopped the turn."
      case .compacted: return "The agent compacted its context."
      case .command(let command): return "Command: \(command)"
      case .shell(let run): return "Shell: \(run.command)"
      case .error(let text): return "Error: \(text)"
      case .information(let text): return "Information: \(text)"
      case .chapter(let provider, _): return "— A new conversation with \(provider) starts here."
      case .olderFormat: return nil
      }
    }
  }

  private static func state(of state: ToolCallState) -> String {
    switch state {
    case .running: return "running"
    case .awaitingPermission: return "waiting for the user's permission"
    case .succeeded: return "done"
    case .failed: return "failed"
    case .refused: return "refused"
    default: return "stopped"
    }
  }

  static func oneLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).joined(separator: " ")
  }

  public static func cut(_ text: String, to limit: Int) -> String {
    text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
  }
}
