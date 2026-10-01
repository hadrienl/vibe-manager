import Foundation
import Testing

@testable import VibeApplication

/// A generator of fixed seed: the same conversations at every run, and on every machine.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    // SplitMix64.
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}

/// Conversations of every shape the grouping looks at: tools of mixed families, reasoning with and
/// without text, sub-agents, prompts, a call waiting for a permission.
enum RandomConversation {
  static func entries(count: Int, using generator: inout SeededGenerator) -> [ConversationEntry] {
    let kinds: [ToolKind] = [.read, .edit, .create, .shell, .search, .list, .todo, .image]
    return (0..<count).map { index in
      let id = "e\(index)"
      switch Int.random(in: 0..<10, using: &generator) {
      case 0:
        return ConversationEntry(id: id, content: .userPrompt("prompt \(index)", attachments: []))
      case 1: return ConversationEntry(id: id, content: .agentText("text \(index)"))
      case 2: return ConversationEntry(id: id, content: .reasoning(nil))
      case 3: return ConversationEntry(id: id, content: .reasoning("thought \(index)"))
      case 4:
        let state: ToolCallState = Bool.random(using: &generator) ? .running : .succeeded
        return ConversationEntry(
          id: id,
          content: .tool(
            ToolCall(callID: id, kind: .subagent, state: state, subagent: SubagentRun())))
      case 5:
        return ConversationEntry(
          id: id,
          content: .tool(ToolCall(callID: id, kind: .shell, state: .awaitingPermission)))
      case 6:
        return ConversationEntry(
          id: id, content: .tool(ToolCall(callID: id, kind: .read, state: .failed(exitCode: 1))))
      default:
        let kind = kinds[Int.random(in: 0..<kinds.count, using: &generator)]
        return ConversationEntry(id: id, content: .tool(ToolCall(callID: id, kind: kind)))
      }
    }
  }
}

@Suite("Laying out a conversation from where it changed (#250)")
struct ConversationGroupingIncrementalTests {
  private static func notReasoning(_ entry: ConversationEntry) -> Bool {
    if case .reasoning = entry.content { return false }
    return true
  }

  @Test(
    "Laid out again from the block to restart from, the blocks are those of a full layout",
    arguments: [true, false], [true, false])
  func restartGivesTheFullLayout(grouping: Bool, showsReasoning: Bool) {
    var generator = SeededGenerator(seed: grouping ? 250 : 520)
    let includes = { (entry: ConversationEntry) -> Bool in
      showsReasoning || Self.notReasoning(entry)
    }
    for _ in 0..<40 {
      let old = RandomConversation.entries(count: 60, using: &generator)
      var oldBlocks: [ConversationBlock] = []
      var oldStarts: [Int] = []
      ConversationGrouping.group(
        old, from: 0, grouping: grouping, includes: includes, into: &oldBlocks,
        starts: &oldStarts)
      #expect(oldBlocks == ConversationGrouping.blocks(old.filter(includes), grouping: grouping))
      // Every place a change can start from: the entries after it replaced, some added.
      for cut in 0...old.count {
        let tail = RandomConversation.entries(
          count: Int.random(in: 0..<8, using: &generator), using: &generator
        ).map { ConversationEntry(id: "n\($0.id)", content: $0.content) }
        let new = Array(old[..<cut]) + tail
        let restart = ConversationGrouping.restartBlock(
          starts: oldStarts, blocks: oldBlocks, changedFrom: cut)
        var blocks = Array(oldBlocks[..<restart])
        var starts = Array(oldStarts[..<restart])
        ConversationGrouping.group(
          new, from: restart == 0 ? 0 : oldStarts[restart], grouping: grouping,
          includes: includes, into: &blocks, starts: &starts)
        var fullBlocks: [ConversationBlock] = []
        var fullStarts: [Int] = []
        ConversationGrouping.group(
          new, from: 0, grouping: grouping, includes: includes, into: &fullBlocks,
          starts: &fullStarts)
        #expect(blocks == fullBlocks, "cut at \(cut)")
        #expect(starts == fullStarts, "cut at \(cut)")
      }
    }
  }

  @Test("Each block starts at its first entry, in order")
  func starts() {
    let entries = [
      ConversationEntry(id: "p", content: .userPrompt("go", attachments: [])),
      ConversationEntry(id: "r1", content: .tool(ToolCall(callID: "r1", kind: .read))),
      ConversationEntry(id: "silent", content: .reasoning(nil)),
      ConversationEntry(id: "r2", content: .tool(ToolCall(callID: "r2", kind: .read))),
      ConversationEntry(id: "t1", content: .reasoning("one")),
      ConversationEntry(id: "t2", content: .reasoning("two")),
      ConversationEntry(id: "a", content: .agentText("done")),
    ]
    var blocks: [ConversationBlock] = []
    var starts: [Int] = []
    ConversationGrouping.group(entries, from: 0, grouping: true, into: &blocks, starts: &starts)
    #expect(blocks.map(\.id) == ["p", "group:r1", "t1", "a"])
    #expect(starts == [0, 1, 4, 6])
  }
}
