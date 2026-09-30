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
    var starts: [Int] = []
    group(entries, from: 0, grouping: grouping, into: &blocks, starts: &starts)
    return blocks
  }

  /// Lays out `entries` from `start` on, after `blocks`: those laid out for the entries before
  /// it, each with the index of its first entry in `starts` (#250).
  ///
  /// - Parameter includes: the entries shown; the others are passed over.
  public static func group(
    _ entries: [ConversationEntry], from start: Int, grouping: Bool,
    includes: (ConversationEntry) -> Bool = { _ in true },
    into blocks: inout [ConversationBlock], starts: inout [Int]
  ) {
    var pending: [ConversationEntry] = []
    var pendingStart = 0
    /// Reasoning without text, seen while a group was open: kept aside until it is known whether
    /// the group goes on, in which case it is folded in with it rather than shown between calls.
    var silentReasoning: [(index: Int, entry: ConversationEntry)] = []
    /// Sub-agents started one after the other: folded together whatever the grouping setting,
    /// since they run together.
    var subagents: [ConversationEntry] = []
    var subagentsStart = 0

    func append(_ block: ConversationBlock, at index: Int) {
      blocks.append(block)
      starts.append(index)
    }

    func flush() {
      if subagents.count > 1, let first = subagents.first {
        append(.subagentGroup(id: first.id, runs: subagents), at: subagentsStart)
      } else if let only = subagents.first {
        append(.entry(only), at: subagentsStart)
      }
      subagents = []
      if pending.count > 1, let first = pending.first {
        append(.toolGroup(id: first.id, calls: pending), at: pendingStart)
      } else if let only = pending.first {
        append(.entry(only), at: pendingStart)
      }
      pending = []
      for (index, entry) in silentReasoning { append(.entry(entry), at: index) }
      silentReasoning = []
    }

    for index in entries.indices.dropFirst(start) {
      let entry = entries[index]
      guard includes(entry) else { continue }
      if entry.subagentCall != nil {
        if subagents.isEmpty {
          flush()
          subagentsStart = index
        }
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
        pendingStart = index
        continue
      }
      if case .reasoning(nil) = entry.content, !pending.isEmpty {
        silentReasoning.append((index, entry))
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
      append(.entry(entry), at: index)
    }
    flush()
  }

  /// The block to lay out again from when the entries change from `index` on: the one that holds
  /// it, and one more before — a group, or sub-agents started together, take in what follows
  /// them — then back past reasoning, which a group that goes on swallows and which joins the
  /// reasoning before it (#250).
  ///
  /// The blocks before it are the same whatever follows them: `group` from the start of this one
  /// gives what `blocks` gives from the start of the conversation.
  public static func restartBlock(
    starts: [Int], blocks: [ConversationBlock], changedFrom index: Int
  ) -> Int {
    guard let holding = starts.lastIndex(where: { $0 <= index }) else { return 0 }
    var restart = max(0, holding - 1)
    while restart > 0, case .entry(let entry) = blocks[restart],
      case .reasoning = entry.content
    {
      restart -= 1
    }
    return restart
  }
}
