import Foundation
import VibeDomain

/// What a summary pass sends: the turns since the last one, condensed without any model (#36).
///
/// Never the transcript and never a tool's output: the prompts, one line per action, the agent's
/// last words of each turn, the resources the pass found and the latest entries, for continuity.
/// Bounded, the actions in the middle of the longest turns replaced by their count first.
public enum TurnDigest {
  public static let byteLimit = 16 * 1024
  public static let promptLimit = 1_000
  public static let actionLimit = 200
  public static let agentTextLimit = 1_500
  public static let recentEntryCount = 10

  public static func make(
    turns: [DigestTurn], resources: [SessionResource], recentEntries: [JournalEntry]
  ) -> String {
    var turns = turns.map(clipped)
    var text = render(turns, resources: resources, recentEntries: recentEntries)
    // Each round halves the actions of the busiest turn, then shortens what was said.
    var rounds = 0
    while text.utf8.count > byteLimit, rounds < 64 {
      rounds += 1
      if let busiest = turns.indices.max(by: { turns[$0].actions.count < turns[$1].actions.count }),
        turns[busiest].actions.count > 2
      {
        let actions = turns[busiest].actions
        let keep = actions.count / 4
        turns[busiest].actions = Array(actions.prefix(keep)) + Array(actions.suffix(keep))
        turns[busiest].omittedActions += actions.count - keep * 2
      } else {
        // Turns are shortened, never dropped: the entries are dated by their number.
        let promptLimit = rounds > 8 ? 60 : 200
        for index in turns.indices {
          turns[index].prompts = turns[index].prompts.map { clip($0, to: promptLimit) }
          turns[index].agentText = turns[index].agentText.map { clip($0, to: promptLimit) }
          if rounds > 8 {
            turns[index].omittedActions += turns[index].actions.count
            turns[index].actions = []
          }
        }
      }
      text = render(turns, resources: resources, recentEntries: recentEntries)
    }
    return text.utf8.count > byteLimit
      ? String(decoding: Data(text.utf8.prefix(byteLimit)), as: UTF8.self) : text
  }

  static func clipped(_ turn: DigestTurn) -> DigestTurn {
    var turn = turn
    turn.prompts = turn.prompts.map { clip($0, to: promptLimit) }
    turn.actions = turn.actions.map { clip(firstLine($0), to: actionLimit) }
    turn.agentText = turn.agentText.map { clip($0, to: agentTextLimit) }
    return turn
  }

  static func render(
    _ turns: [DigestTurn], resources: [SessionResource], recentEntries: [JournalEntry]
  ) -> String {
    var lines: [String] = []
    for (index, turn) in turns.enumerated() {
      lines.append("## Turn \(index + 1)")
      for prompt in turn.prompts {
        lines.append("User asked: \(prompt)")
      }
      if !turn.actions.isEmpty || turn.omittedActions > 0 {
        lines.append("Actions:")
        let half = turn.actions.count / 2
        for (position, action) in turn.actions.enumerated() {
          if position == half, turn.omittedActions > 0, turn.actions.count > 1 {
            lines.append("- … \(turn.omittedActions) more actions")
          }
          lines.append("- \(action)")
        }
        if turn.actions.count <= 1, turn.omittedActions > 0 {
          lines.append("- … \(turn.omittedActions) more actions")
        }
      }
      if let agentText = turn.agentText {
        lines.append("Agent said last: \(agentText)")
      }
      lines.append("")
    }
    if !resources.isEmpty {
      lines.append("## Resources used")
      for resource in resources {
        lines.append("- \(describe(resource))")
      }
      lines.append("")
    }
    if !recentEntries.isEmpty {
      lines.append("## Latest journal entries")
      for entry in recentEntries.suffix(recentEntryCount) where entry.foldedCount == nil {
        lines.append("- \(entry.text)")
      }
    }
    return lines.joined(separator: "\n")
  }

  static func describe(_ resource: SessionResource) -> String {
    let kind: String
    switch resource.kind {
    case .issue: kind = "issue"
    case .pullRequest: kind = "pull/merge request"
    case .branch: kind = "branch"
    case .worktree: kind = "worktree"
    }
    var parts = ["\(kind) \(resource.label)"]
    if let context = resource.context { parts.append("(\(context))") }
    switch resource.target {
    case .web(let url): parts.append(url.absoluteString)
    case .branch(_, let url?): parts.append(url.absoluteString)
    case .folder(let path): parts.append(path)
    case .branch: break
    }
    return parts.joined(separator: " ")
  }

  static func firstLine(_ text: String) -> String {
    text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(
      String.init)
      ?? ""
  }

  static func clip(_ text: String, to limit: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
  }
}
