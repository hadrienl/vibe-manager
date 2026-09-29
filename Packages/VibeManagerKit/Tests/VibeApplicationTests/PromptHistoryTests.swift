import Foundation
import Testing

@testable import VibeApplication

@Suite("The messages ↑ and ↓ recall in the composer (#123)")
struct PromptHistoryTests {
  private func prompt(_ text: String, attachments: Int = 0) -> ConversationEntry {
    ConversationEntry(id: UUID().uuidString, content: .userPrompt(text, attachments: attachments))
  }

  @Test("The transcript's prompts in order, then those sent and not written yet")
  func order() {
    let history = PromptHistory(
      entries: [
        prompt("first"), ConversationEntry(id: "a", content: .agentText("answer")),
        prompt("second"),
      ],
      pending: ["third"])
    #expect(history.prompts == ["first", "second", "third"])
  }

  @Test("Consecutive duplicates are one message; apart, both stay")
  func duplicates() {
    let history = PromptHistory(
      entries: [prompt("go"), prompt("go "), prompt("stop"), prompt("go")], pending: ["go"])
    #expect(history.prompts == ["go", "stop", "go"])
  }

  @Test("Empty messages, images alone and the CLI's notices are left out")
  func leftOut() {
    let history = PromptHistory(entries: [
      prompt("  \n"), prompt("", attachments: 2),
      ConversationEntry(id: "c", content: .notice(.command("/model"))),
      ConversationEntry(id: "s", content: .notice(.shell(command: "ls", output: nil))),
      prompt("kept\n"),
    ])
    #expect(history.prompts == ["kept"])
  }
}

@Suite("Moving through the history with ↑ and ↓ (#123)")
struct PromptHistoryNavigationTests {
  private let history = PromptHistory(prompts: ["one", "two", "three"])

  @Test("With no message sent, ↑ does nothing")
  func empty() {
    var navigation = PromptHistoryNavigation()
    #expect(navigation.older(in: PromptHistory(prompts: []), draft: "draft") == nil)
    #expect(!navigation.isNavigating)
  }

  @Test("↑ goes back to the oldest, and stops there")
  func up() {
    var navigation = PromptHistoryNavigation()
    #expect(navigation.older(in: history, draft: "") == "three")
    #expect(navigation.older(in: history, draft: "three") == "two")
    #expect(navigation.older(in: history, draft: "two") == "one")
    #expect(navigation.older(in: history, draft: "one") == nil)
    #expect(navigation.index == 0)
  }

  @Test("↓ comes back, and past the most recent gives the draft back")
  func down() {
    var navigation = PromptHistoryNavigation()
    #expect(navigation.newer(in: history, draft: "draft") == nil)
    _ = navigation.older(in: history, draft: "draft")
    _ = navigation.older(in: history, draft: "three")
    #expect(navigation.newer(in: history, draft: "two") == "three")
    #expect(navigation.newer(in: history, draft: "three") == "draft")
    #expect(!navigation.isNavigating)
    #expect(navigation.newer(in: history, draft: "draft") == nil)
  }

  @Test("Escape gives the draft back")
  func cancel() {
    var navigation = PromptHistoryNavigation()
    #expect(navigation.cancel(in: history, draft: "draft") == nil)
    _ = navigation.older(in: history, draft: "draft")
    _ = navigation.older(in: history, draft: "three")
    #expect(navigation.cancel(in: history, draft: "two") == "draft")
    #expect(!navigation.isNavigating)
  }

  @Test("A message arriving meanwhile moves nothing; a history grown shorter bounds the place")
  func historyChanges() {
    var navigation = PromptHistoryNavigation()
    _ = navigation.older(in: history, draft: "")
    _ = navigation.older(in: history, draft: "three")
    let grown = PromptHistory(prompts: ["one", "two", "three", "four"])
    #expect(navigation.older(in: grown, draft: "two") == "one")
    #expect(navigation.newer(in: grown, draft: "one") == "two")
    var last = PromptHistoryNavigation()
    _ = last.older(in: grown, draft: "")
    #expect(last.index == 3)
    #expect(last.older(in: PromptHistory(prompts: ["one", "four"]), draft: "four") == "one")
  }

  @Test("A recalled message edited is a draft: ↑ puts it aside and starts from the most recent")
  func edited() {
    var navigation = PromptHistoryNavigation()
    _ = navigation.older(in: history, draft: "original")
    _ = navigation.older(in: history, draft: "three")
    #expect(navigation.cancel(in: history, draft: "two, edited") == nil)
    #expect(navigation.older(in: history, draft: "two, edited") == "three")
    #expect(navigation.newer(in: history, draft: "three") == "two, edited")
    #expect(history.prompts == ["one", "two", "three"])
  }
}
