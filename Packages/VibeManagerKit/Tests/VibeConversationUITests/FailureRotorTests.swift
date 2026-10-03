import Testing
import VibeApplication

@testable import VibeConversationUI

/// The rotor of failures names what failed, never the call's identifier (#232).
@MainActor
@Suite("The Failures rotor")
struct FailureRotorTests {
  @Test("A failed call is named by its tool and its target, not by its identifier")
  func namesTheCall() {
    let call = ToolCall(
      callID: "toolu_01AbCdEf", kind: .read, state: .failed(exitCode: 1),
      parameters: [ToolParameter(.path, "/repo/Sources/App.swift")])
    let block = ConversationBlock.entry(
      ConversationEntry(id: "toolu_01AbCdEf", content: .tool(call)))
    let name = ToolBlockView.accessibilityTitle(of: block)
    #expect(!name.contains("toolu_01AbCdEf"))
    #expect(name.contains("App.swift"))
    #expect(name.contains(StateSymbol.label(for: .failed(exitCode: 1))))
  }

  @Test("A group says the commands it ran, and says failed once")
  func namesTheGroup() {
    let calls = ["make test", "make lint"].enumerated().map { index, command in
      ConversationEntry(
        id: "call-\(index)",
        content: .tool(
          ToolCall(
            callID: "call-\(index)", kind: .shell, state: .failed(exitCode: 2),
            parameters: [ToolParameter(.command, command)])))
    }
    let block = ConversationBlock.toolGroup(id: "group:call-0", calls: calls)
    let name = ToolBlockView.accessibilityTitle(of: block)
    #expect(!name.contains("group:"))
    #expect(name.contains("make test"))
    #expect(name.contains("make lint"))
    let failed = StateSymbol.label(for: .failed(exitCode: 2))
    #expect(name.components(separatedBy: ", ").filter { $0 == failed }.isEmpty, "\(name)")
  }

  @Test("A group of sub-agents is named by what they were asked")
  func namesTheSubagents() {
    let runs = ["Review the parser", "Write the tests"].enumerated().map { index, task in
      ConversationEntry(
        id: "agent-\(index)",
        content: .tool(
          ToolCall(
            callID: "agent-\(index)", kind: .subagent,
            state: index == 0 ? .failed(exitCode: nil) : .succeeded,
            parameters: [ToolParameter(.description, task)], subagent: SubagentRun())))
    }
    let block = ConversationBlock.subagentGroup(id: "group:agent-0", runs: runs)
    let name = ToolBlockView.accessibilityTitle(of: block)
    #expect(name.contains("Review the parser"), "\(name)")
    #expect(!name.contains("group:"))
  }

  @Test("A failed call without an exit code says failed once")
  func failedOnce() {
    let call = ToolCall(
      callID: "c", kind: .shell, state: .failed(exitCode: nil),
      parameters: [ToolParameter(.command, "make test")])
    let name = ToolBlockView.accessibilityTitle(
      of: .entry(ConversationEntry(id: "c", content: .tool(call))))
    let failed = StateSymbol.label(for: .failed(exitCode: nil))
    #expect(name.components(separatedBy: failed).count <= 2, "\(name)")
  }

  @Test("A target whose name holds the state's word does not silence the state")
  func stateKeptBesideItsWord() {
    let call = ToolCall(
      callID: "r", kind: .read, state: .failed(exitCode: nil),
      parameters: [ToolParameter(.path, "/logs/failed.log")])
    let name = ToolBlockView.accessibilityTitle(
      of: .entry(ConversationEntry(id: "r", content: .tool(call))))
    let failed = StateSymbol.label(for: .failed(exitCode: nil))
    #expect(name.components(separatedBy: ", ").contains(failed), "\(name)")
  }
}
