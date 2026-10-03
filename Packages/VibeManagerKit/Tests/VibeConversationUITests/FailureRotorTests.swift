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

  @Test("A group of calls is named by what they did, not by its group identifier")
  func namesTheGroup() {
    let calls = (1...2).map { index in
      ConversationEntry(
        id: "call-\(index)",
        content: .tool(
          ToolCall(
            callID: "call-\(index)", kind: .shell, state: .failed(exitCode: 2),
            parameters: [ToolParameter(.command, "make test")])))
    }
    let block = ConversationBlock.toolGroup(id: "group:call-1", calls: calls)
    let name = ToolBlockView.accessibilityTitle(of: block)
    #expect(!name.contains("group:"))
    #expect(!name.isEmpty)
  }
}
