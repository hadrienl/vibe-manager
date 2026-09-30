import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

/// A generator of fixed seed: the same conversations at every run.
private struct Seeded: RandomNumberGenerator {
  private var state: UInt64
  init(_ seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}

@Suite("Laying the conversation out from where it changed (#250)")
@MainActor
struct ConversationModelIncrementalTests {
  private static let kinds: [ToolKind] = [.read, .edit, .shell, .search, .todo]

  private static func entry(_ id: String, using generator: inout Seeded) -> ConversationEntry {
    switch Int.random(in: 0..<9, using: &generator) {
    case 0: return ConversationEntry(id: id, content: .userPrompt("prompt \(id)", attachments: 0))
    case 1: return ConversationEntry(id: id, content: .agentText("text \(id)"))
    case 2: return ConversationEntry(id: id, content: .reasoning(nil))
    case 3: return ConversationEntry(id: id, content: .reasoning("thought \(id)"))
    case 4:
      let state: ToolCallState = Bool.random(using: &generator) ? .running : .succeeded
      return ConversationEntry(
        id: id,
        content: .tool(
          ToolCall(
            callID: id, kind: .subagent, state: state,
            subagent: SubagentRun(startedAt: Date(timeIntervalSince1970: 1_000)))))
    case 5:
      return ConversationEntry(
        id: id, content: .tool(ToolCall(callID: id, kind: .read, state: .failed(exitCode: 1))))
    case 6: return ConversationEntry(id: id, content: .notice(.shell(ShellRun(command: "ls"))))
    default:
      let kind = kinds[Int.random(in: 0..<kinds.count, using: &generator)]
      let state: ToolCallState = Bool.random(using: &generator) ? .running : .succeeded
      return ConversationEntry(
        id: id, content: .tool(ToolCall(callID: id, kind: kind, state: state)))
    }
  }

  private static func commonPrefix(_ old: [ConversationEntry], _ new: [ConversationEntry]) -> Int {
    var index = 0
    while index < min(old.count, new.count), old[index] == new[index] { index += 1 }
    return index
  }

  private static func snapshot(
    _ entries: [ConversationEntry], revision: Int, unchangedPrefix: Int,
    availability: ConversationSnapshot.Availability = .available
  ) -> ConversationSnapshot {
    var snapshot = ConversationSnapshot(entries: entries, availability: availability)
    snapshot.revision = revision
    snapshot.unchangedPrefix = unchangedPrefix
    return snapshot
  }

  private func expectSameLayout(
    _ incremental: ConversationModel, _ full: ConversationModel, _ step: String
  ) {
    #expect(incremental.shownEntries == full.shownEntries, "\(step)")
    #expect(incremental.blocks == full.blocks, "\(step)")
    // Those that ended at the same instant linger in no set order, laid out in full or not.
    #expect(
      incremental.trayItems.filter { !$0.hasEnded } == full.trayItems.filter { !$0.hasEnded },
      "\(step)")
    #expect(Set(incremental.trayItems) == Set(full.trayItems), "\(step)")
    #expect(incremental.rotor == full.rotor, "\(step)")
    #expect(incremental.scrollToBottomRequest == full.scrollToBottomRequest, "\(step)")
  }

  @Test(
    "Told what did not change, the model lays out what a full layout gives, step by step",
    arguments: [1, 2, 3, 4])
  func incrementalIsFull(seed: UInt64) {
    var generator = Seeded(seed)
    var running = true
    let incremental = ConversationModel(sessionID: SessionID())
    let full = ConversationModel(sessionID: SessionID())
    for model in [incremental, full] { model.processRunning = { running } }
    var entries: [ConversationEntry] = []
    for step in 1...120 {
      // Mostly at the end, as a transcript grows; sometimes a result further up.
      let cut =
        Int.random(in: 0..<4, using: &generator) == 0
        ? Int.random(in: 0...entries.count, using: &generator)
        : max(0, entries.count - Int.random(in: 0...2, using: &generator))
      let added = (0..<Int.random(in: 0...4, using: &generator)).map {
        Self.entry("s\(step)-\($0)", using: &generator)
      }
      var next = Array(entries[..<cut]) + added
      if !next.isEmpty, Int.random(in: 0..<5, using: &generator) == 0 {
        // A call up the conversation gets its result.
        let index = Int.random(in: 0..<next.count, using: &generator)
        if case .tool(var call) = next[index].content, call.kind != .subagent {
          call.state = .succeeded
          next[index].content = .tool(call)
        }
      }
      let prefix = Self.commonPrefix(entries, next)
      entries = next
      incremental.apply(Self.snapshot(entries, revision: step, unchangedPrefix: prefix))
      full.apply(Self.snapshot(entries, revision: 0, unchangedPrefix: 0))
      expectSameLayout(incremental, full, "step \(step)")
      switch Int.random(in: 0..<12, using: &generator) {
      case 0:
        for model in [incremental, full] { model.activity = .awaitingUser(.approval) }
      case 1:
        for model in [incremental, full] { model.activity = .working }
      case 2:
        running.toggle()
        for model in [incremental, full] { model.processStateChanged() }
      case 3:
        let grouping = Bool.random(using: &generator)
        for model in [incremental, full] { model.appearance.groupsToolCalls = grouping }
      case 4:
        let reasoning = Bool.random(using: &generator)
        for model in [incremental, full] { model.appearance.showsReasoning = reasoning }
      default:
        continue
      }
      expectSameLayout(incremental, full, "step \(step), after a change of state")
    }
  }

  @Test("One entry added to ten thousand lays out a handful of entries and blocks")
  func boundedWork() {
    let model = ConversationModel(sessionID: SessionID())
    model.processRunning = { true }
    var entries = (0..<10_000).map { index in
      index.isMultiple(of: 2)
        ? ConversationEntry(id: "p\(index)", content: .userPrompt("prompt", attachments: 0))
        : ConversationEntry(id: "a\(index)", content: .agentText("answer"))
    }
    model.apply(Self.snapshot(entries, revision: 1, unchangedPrefix: 0))
    #expect(model.lastLayoutWork.entries == 10_000)
    entries.append(ConversationEntry(id: "last", content: .agentText("more")))
    model.apply(Self.snapshot(entries, revision: 2, unchangedPrefix: 10_000))
    #expect(model.lastLayoutWork.entries == 1)
    #expect(model.lastLayoutWork.blocks <= 3)
    #expect(model.blocks.count == 10_001)
    #expect(model.blocks.last?.id == "last")
  }

  @Test("A publication missed, or a stream started again: laid out from the start")
  func missedRevision() {
    let model = ConversationModel(sessionID: SessionID())
    model.processRunning = { true }
    let first = [
      ConversationEntry(id: "a", content: .agentText("one")),
      ConversationEntry(id: "b", content: .agentText("two")),
    ]
    model.apply(Self.snapshot(first, revision: 1, unchangedPrefix: 0))
    // Revision 2 never came: what 3 says it kept is kept from 2, not from here.
    let third = [
      ConversationEntry(id: "x", content: .userPrompt("other", attachments: 0)),
      ConversationEntry(id: "b", content: .agentText("two")),
    ]
    model.apply(Self.snapshot(third, revision: 3, unchangedPrefix: 2))
    #expect(model.blocks.map(\.id) == ["x", "b"])
    #expect(model.lastLayoutWork.entries == 2)
  }

  @Test("Hidden, nothing is laid out and echoes are still confirmed; shown, laid out once")
  func hidden() async {
    let hidden = ConversationModel(sessionID: SessionID())
    let shown = ConversationModel(sessionID: SessionID())
    var told: [(Bool, Int)] = []
    hidden.shownChanged = { told.append(($0, $1)) }
    for model in [hidden, shown] {
      model.processRunning = { true }
      model.write = { _ in }
      model.promptFormat = AgentPromptFormat(submitDelay: .zero)
      model.apply(ConversationSnapshot(availability: .available))
    }
    hidden.draft = "hello"
    #expect(await hidden.send())
    #expect(hidden.echoes.count == 1)
    hidden.setShown(false)
    #expect(told.map(\.0) == [false])
    let layouts = hidden.layoutCount
    var entries: [ConversationEntry] = []
    for step in 1...3 {
      let previous = entries.count
      entries.append(
        step == 2
          ? ConversationEntry(id: "p", content: .userPrompt("hello", attachments: 0))
          : ConversationEntry(id: "a\(step)", content: .agentText("answer \(step)")))
      for model in [hidden, shown] {
        model.apply(Self.snapshot(entries, revision: step, unchangedPrefix: previous))
      }
    }
    #expect(hidden.layoutCount == layouts)
    #expect(hidden.blocks.isEmpty)
    #expect(hidden.echoes.isEmpty)
    hidden.activity = .working
    shown.activity = .working
    #expect(hidden.layoutCount == layouts)
    hidden.setShown(true)
    #expect(told.map(\.0) == [false, true])
    #expect(told[1].1 > told[0].1)
    #expect(hidden.layoutCount == layouts + 1)
    #expect(hidden.snapshot == shown.snapshot)
    #expect(hidden.shownEntries == shown.shownEntries)
    #expect(hidden.blocks == shown.blocks)
    #expect(hidden.rotor == shown.rotor)
  }

  @Test("The rotors list the prompts, the failures and the sub-agents among the blocks")
  func rotors() {
    let model = ConversationModel(sessionID: SessionID())
    model.processRunning = { true }
    let entries = [
      ConversationEntry(id: "p", content: .userPrompt("go", attachments: 0)),
      ConversationEntry(
        id: "f", content: .tool(ToolCall(callID: "f", kind: .read, state: .failed(exitCode: 1)))),
      ConversationEntry(id: "t", content: .agentText("…")),
      ConversationEntry(
        id: "s", content: .tool(ToolCall(callID: "s", kind: .subagent, subagent: SubagentRun()))),
    ]
    model.apply(Self.snapshot(entries, revision: 1, unchangedPrefix: 0))
    #expect(model.promptBlocks.map(\.id) == ["p"])
    #expect(model.failureBlocks.map(\.id) == ["f"])
    #expect(model.subagentBlocks.map(\.id) == ["s"])
  }
}
