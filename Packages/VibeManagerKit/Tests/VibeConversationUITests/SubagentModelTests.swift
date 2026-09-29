import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

@Suite("Sub-agents in the conversation model")
@MainActor
struct SubagentModelTests {
  private func subagent(
    _ id: String, _ state: ToolCallState = .running, agentID: String? = nil,
    inner: [ConversationEntry]? = nil
  ) -> ConversationEntry {
    ConversationEntry(
      id: id,
      content: .tool(
        ToolCall(
          callID: id, kind: .subagent, state: state,
          parameters: [ToolParameter(.description, "Task \(id)")],
          subagent: SubagentRun(
            agentID: agentID, mode: .background, startedAt: Date(),
            activity: inner.map(SubagentActivity.read) ?? .unread))))
  }

  private func command(_ id: String, _ text: String) -> ConversationEntry {
    ConversationEntry(
      id: id,
      content: .tool(
        ToolCall(callID: id, kind: .shell, parameters: [ToolParameter(.command, text)])))
  }

  private func model(running: Bool = true) -> ConversationModel {
    let model = ConversationModel(sessionID: SessionID())
    model.processRunning = { running }
    return model
  }

  private func show(_ entries: [ConversationEntry], in model: ConversationModel) {
    model.apply(ConversationSnapshot(entries: entries, availability: .available))
  }

  @Test("The bar lists the sub-agents running at any depth, then keeps one that ended a moment")
  func tray() async throws {
    let model = model()
    model.trayLinger = .milliseconds(100)
    show([subagent("a", inner: [subagent("a1")]), subagent("b")], in: model)
    #expect(model.trayItems.map(\.id) == ["a", "a1", "b"])
    #expect(model.trayItems.allSatisfy { !$0.hasEnded })
    show([subagent("a", inner: [subagent("a1")]), subagent("b", .succeeded)], in: model)
    #expect(model.trayItems.map(\.id) == ["a", "a1", "b"])
    #expect(model.trayItems.last?.hasEnded == true)
    // Waits for the state, not for a moment: a loaded runner can hold the main actor a while.
    for _ in 0..<500 where model.trayItems.count == 3 {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(model.trayItems.map(\.id) == ["a", "a1"])
  }

  @Test("A sub-agent whose end never came is stopped once the agent no longer runs")
  func settled() {
    let model = model(running: false)
    show([subagent("a", inner: [command("c", "ls")])], in: model)
    let call = model.shownEntries.first?.toolCall
    #expect(call?.state == .interrupted)
    #expect(call?.subagent?.activityEntries?.first?.toolCall?.state == .interrupted)
    #expect(model.trayItems.isEmpty)
  }

  @Test("The agent's state is told to the reader when it changes, not at each rebuild")
  func agentRunningReported() {
    var running = true
    let model = ConversationModel(sessionID: SessionID())
    model.processRunning = { running }
    var told: [Bool] = []
    model.agentRunningChanged = { told.append($0) }
    show([subagent("a")], in: model)
    show([subagent("a")], in: model)
    running = false
    model.activity = .idle
    #expect(told == [true, false])
  }

  @Test("The process ending with the agent idle still settles its sub-agents")
  func processEndsWhileIdle() {
    var running = true
    let model = ConversationModel(sessionID: SessionID())
    model.processRunning = { running }
    var told: [Bool] = []
    model.agentRunningChanged = { told.append($0) }
    model.activity = .idle
    show([subagent("a")], in: model)
    #expect(model.trayItems.map(\.id) == ["a"])
    running = false
    model.processStateChanged()
    #expect(model.shownEntries.first?.toolCall?.state == .interrupted)
    #expect(model.trayItems.allSatisfy { $0.hasEnded })
    #expect(told == [true, false])
    model.processStateChanged()
    #expect(told == [true, false])
  }

  @Test("A permission a sub-agent asks for is answered under its own call")
  func permissionInsideASubagent() {
    let model = model()
    show(
      [
        command("main", "make"),
        subagent("s", agentID: "agent-s", inner: [command("inner", "swift test")]),
      ],
      in: model)
    let request = AgentRequest(
      id: AgentRequestID(sessionID: model.sessionID, key: "p"), receivedAt: Date(),
      kind: .approval,
      content: .permission(
        AgentToolPermission(tool: .shell, toolName: "Bash", subject: "swift test")),
      reference: AgentToolReference(tool: "Bash", agentID: "agent-s"), isShown: true)
    model.pendingRequest = {
      ConversationRequest(request: request, answers: [.allowOnce, .deny], isSending: false)
    }
    model.answerRequest = { _, _ in true }
    model.activity = .awaitingUser(.approval)
    #expect(model.pendingCall?.callID == "inner")
    let inner = ConversationEntry.allCalls(in: model.shownEntries).first { $0.callID == "inner" }
    #expect(inner.flatMap(model.request(for:)) != nil)
    #expect(model.shownEntries[0].toolCall?.state == .running)
  }

  @Test("A sub-agent whose activity is not read asks on its own block")
  func permissionOnTheBlock() {
    let model = model()
    show([subagent("s", agentID: "agent-s")], in: model)
    let request = AgentRequest(
      id: AgentRequestID(sessionID: model.sessionID, key: "p"), receivedAt: Date(),
      kind: .approval,
      content: .permission(AgentToolPermission(tool: .shell, toolName: "Bash", subject: "rm x")),
      reference: AgentToolReference(tool: "Bash", agentID: "agent-s"), isShown: true)
    model.pendingRequest = {
      ConversationRequest(request: request, answers: [.allowOnce, .deny], isSending: false)
    }
    model.answerRequest = { _, _ in true }
    model.activity = .awaitingUser(.approval)
    let call = model.shownEntries[0].toolCall
    #expect(call?.state == .awaitingPermission)
    #expect(call.flatMap(model.request(for:)) != nil)
    #expect(call.map(model.isSubagentExpanded) == true)
  }

  @Test("Revealing a sub-agent unfolds the way down to it and asks to read the activity above")
  func reveal() {
    let model = model()
    var unfolded: Set<String> = []
    model.unfoldSubagents = { unfolded = $0 }
    show(
      [
        subagent("x", .succeeded),
        subagent("a", inner: [subagent("a1")]),
        ConversationEntry(id: "t", content: .agentText("meanwhile")),
      ], in: model)
    model.revealSubagent("a1")
    #expect(model.revealedBlockID == "subagents:x")
    #expect(model.revealRequest == 1)
    #expect(model.isExpanded(id: ConversationModel.activityToggleID("a"), default: false))
    #expect(model.isExpanded(id: ConversationModel.rowToggleID("a"), default: false))
    #expect(model.isExpanded(id: ConversationModel.rowToggleID("a1"), default: false))
    #expect(unfolded == ["a"])
    #expect(model.scroll.isFollowing == false)
  }

  @Test("Folding an activity stops its reading; a block without its answer reads it when opened")
  func unfolding() {
    let model = model()
    var unfolded: Set<String> = []
    model.unfoldSubagents = { unfolded = $0 }
    let done = ToolCall(
      callID: "c", kind: .subagent, state: .succeeded, subagent: SubagentRun(mode: .background))
    show([ConversationEntry(id: "c", content: .tool(done))], in: model)
    model.setSubagentExpanded(true, call: done)
    #expect(unfolded == ["c"])
    model.setSubagentExpanded(false, call: done)
    #expect(unfolded.isEmpty)
    model.setSubagentActivityExpanded(true, callID: "c")
    model.setSubagentExpanded(false, call: done)
    #expect(unfolded == ["c"])
    model.setSubagentActivityExpanded(false, callID: "c")
    #expect(unfolded.isEmpty)
  }

  @Test("The words of a sub-agent: its figures, its outcome, what VoiceOver says")
  func presentation() {
    var call = ToolCall(
      callID: "c", kind: .subagent, state: .succeeded,
      parameters: [ToolParameter(.description, "Review the diff")],
      subagent: SubagentRun(
        type: "Explore", usage: SubagentUsage(toolUses: 9, duration: .seconds(62))))
    #expect(SubagentPresentation.description(of: call) == "Review the diff")
    #expect(SubagentPresentation.figures(of: call, now: Date()).contains("9"))
    #expect(SubagentPresentation.outcome(of: call) == nil)
    let label = SubagentPresentation.accessibilityLabel(for: call)
    #expect(label.contains("Explore") && label.contains("Review the diff"))
    call.state = .interrupted
    #expect(SubagentPresentation.outcome(of: call) != nil)
    #expect(SubagentPresentation.groupTitle([call, call]).contains("2"))
  }
}
