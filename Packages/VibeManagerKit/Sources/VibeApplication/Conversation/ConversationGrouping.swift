import Foundation

/// What the conversation view lays out: an entry on its own, or tool calls folded together.
public enum ConversationBlock: Identifiable, Hashable, Sendable {
  case entry(ConversationEntry)
  /// Consecutive calls of the same family. Named after its first call, so that it keeps its
  /// identity — and its place on screen — while calls are added to it.
  case toolGroup(id: String, calls: [ConversationEntry])
  /// Sub-agents started one after the other, with nothing said between them: started together
  /// (#180). Named after the first, like a group of tools.
  case subagentGroup(id: String, runs: [ConversationEntry])

  public var id: String {
    switch self {
    case .entry(let entry): return entry.id
    case .toolGroup(let id, _): return "group:\(id)"
    case .subagentGroup(let id, _): return "subagents:\(id)"
    }
  }

  /// The most serious state among the calls, so that a failure shows on the folded group.
  public var toolState: ToolCallState? {
    switch self {
    case .entry(let entry): return entry.toolCall?.state
    case .toolGroup(_, let calls), .subagentGroup(_, let calls):
      return calls.compactMap(\.toolCall?.state).max { $0.severity < $1.severity }
    }
  }

  /// The calls the block shows, one or several.
  public var calls: [ToolCall] {
    switch self {
    case .entry(let entry): return entry.toolCall.map { [$0] } ?? []
    case .toolGroup(_, let entries), .subagentGroup(_, let entries):
      return entries.compactMap(\.toolCall)
    }
  }
}

/// Folds consecutive tool calls of the same family into one block (#38).
///
/// Pure: the same entries always give the same blocks, and a block at the top never changes
/// because entries were added at the bottom — a view keeps its identity, and the reader keeps
/// their place.
public enum ConversationGrouping {
  public static func blocks(_ entries: [ConversationEntry], grouping: Bool = true)
    -> [ConversationBlock]
  {
    var blocks: [ConversationBlock] = []
    var pending: [ConversationEntry] = []
    /// Reasoning without text, seen while a group was open: kept aside until it is known whether
    /// the group goes on, in which case it is folded in with it rather than shown between calls.
    var silentReasoning: [ConversationEntry] = []
    /// Sub-agents started one after the other: folded together whatever the grouping setting,
    /// since they run together.
    var subagents: [ConversationEntry] = []

    func flush() {
      if subagents.count > 1, let first = subagents.first {
        blocks.append(.subagentGroup(id: first.id, runs: subagents))
      } else if let only = subagents.first {
        blocks.append(.entry(only))
      }
      subagents = []
      if pending.count > 1, let first = pending.first {
        blocks.append(.toolGroup(id: first.id, calls: pending))
      } else if let only = pending.first {
        blocks.append(.entry(only))
      }
      pending = []
      blocks.append(contentsOf: silentReasoning.map(ConversationBlock.entry))
      silentReasoning = []
    }

    for entry in entries {
      if entry.subagentCall != nil {
        if subagents.isEmpty { flush() }
        subagents.append(entry)
        continue
      }
      if grouping, let call = entry.toolCall, call.kind.isGroupable,
        call.state != .awaitingPermission
      {
        if let last = pending.last?.toolCall, last.kind.family == call.kind.family {
          silentReasoning = []
          pending.append(entry)
          continue
        }
        flush()
        pending = [entry]
        continue
      }
      if case .reasoning(nil) = entry.content, !pending.isEmpty {
        silentReasoning.append(entry)
        continue
      }
      flush()
      // Reasoning next to reasoning is one row: the agent thought, once, for that long.
      if case .reasoning(let text) = entry.content, case .entry(let previous) = blocks.last,
        case .reasoning(let earlier) = previous.content
      {
        let joined = [earlier, text].compactMap { $0 }.joined(separator: "\n\n")
        var merged = previous
        merged.content = .reasoning(joined.isEmpty ? nil : joined)
        blocks[blocks.count - 1] = .entry(merged)
        continue
      }
      blocks.append(.entry(entry))
    }
    flush()
    return blocks
  }
}
