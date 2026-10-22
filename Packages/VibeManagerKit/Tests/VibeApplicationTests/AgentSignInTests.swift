import Foundation
import Testing

@testable import VibeApplication

/// #410: a turn stopped because the CLI's sign-in expired.
struct AgentSignInTests {
  @Test func anExpiredSignInIsKnownByItsErrorOrByWhatItSays() {
    #expect(
      AgentTerminalPrompt(kind: .account, message: "x", error: "authentication_failed")
        .asksToSignIn)
    #expect(
      !AgentTerminalPrompt(kind: .account, message: "Please run /login", error: "billing_error")
        .asksToSignIn)
    // Kept from before the error was recorded.
    #expect(
      AgentTerminalPrompt(kind: .account, message: "Login expired · Please run /login")
        .asksToSignIn)
    #expect(!AgentTerminalPrompt(kind: .permission, message: "Please run /login").asksToSignIn)
  }

  private func prompt(_ text: String) -> ConversationEntry {
    ConversationEntry(id: UUID().uuidString, content: .userPrompt(text, attachments: []))
  }

  private let error = ConversationEntry(
    id: "e", content: .notice(.error("Login expired · Please run /login")))

  @Test func thePromptThatFailedIsTheLastOneTheAgentDidNotAnswer() {
    let entries = [
      prompt("audit"), ConversationEntry(id: "a", content: .agentText("Done.")), prompt("reprends"),
      error,
    ]
    #expect(ConversationEntry.promptFailedOnSignIn(in: entries) == "reprends")
  }

  @Test func aPromptTheAgentAnsweredDidNotFail() {
    let entries = [prompt("audit"), ConversationEntry(id: "a", content: .agentText("Done."))]
    #expect(ConversationEntry.promptFailedOnSignIn(in: entries) == nil)
    #expect(ConversationEntry.promptFailedOnSignIn(in: []) == nil)
  }

  /// #419: the agent had begun on the prompt; without one, nothing is to be gone on with.
  @Test func aTurnBegunBeforeTheSignInExpiredIsToBeGoneOnWith() {
    let begun = [
      prompt("audit"), ConversationEntry(id: "a", content: .agentText("Reading the lockfile.")),
      error,
    ]
    #expect(ConversationEntry.turnFailedOnSignInMidway(in: begun))
    #expect(!ConversationEntry.turnFailedOnSignInMidway(in: [prompt("audit"), error]))
    #expect(!ConversationEntry.turnFailedOnSignInMidway(in: [error]))
  }
}
