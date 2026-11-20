import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

struct RelayedMessageTests {
  private let childID = SessionID(
    rawValue: UUID(uuidString: "F208D4A6-8093-4464-B141-4D613EE52EC0")!)

  @Test func vibeManagerNewsNameEachChildWithoutItsIdentifier() throws {
    let events = [
      CoordinationEvent(
        childID: childID, childName: "#476 failles actives des connecteurs", kind: .turnEnded,
        date: .now),
      CoordinationEvent(childID: childID, childName: "a*b", kind: .stopped, date: .now),
    ]
    let message = try #require(RelayedMessage(CoordinationInbox.message(for: events)))
    #expect(message.sender == .application)
    #expect(message.children == ["#476 failles actives des connecteurs", "a*b"])
    #expect(
      message.body == """
        - **\\#476 failles actives des connecteurs** finished its turn\\.
        - **a\\*b** stopped\\: its agent is no longer running\\.
        """)
  }

  @Test("What a child asks is shown as it was written, not read as Markdown")
  func vibeManagerWordsAreNotMarkdown() throws {
    let event = CoordinationEvent(
      childID: childID, childName: "V2",
      kind: .awaitingUser("permission to run rm -rf __pycache__ *.pyc <config>"), date: .now)
    let message = try #require(RelayedMessage(CoordinationInbox.message(for: [event])))
    #expect(message.body.contains("rm \\-rf \\_\\_pycache\\_\\_ \\*\\.pyc \\<config\\>"))
    #expect(message.body.hasPrefix("- **V2** is waiting"))
  }

  @Test func oneEvent() throws {
    let wake = CoordinationEvent.wake("is #12 merged?", at: .now)
    let message = try #require(RelayedMessage(CoordinationInbox.message(for: [wake])))
    #expect(message.body == "- Wake\\-up you asked for\\: is \\#12 merged\\?")
    #expect(message.children.isEmpty)
  }

  @Test func coordinatorMessage() throws {
    let text = CoordinationPolicy.fromCoordinator(
      "Rebase on main.\n\nThen push.", coordinatorName: "V2")
    let message = try #require(RelayedMessage(text))
    #expect(message.sender == .coordinator("V2"))
    #expect(message.body == "Rebase on main.\n\nThen push.")
  }

  @Test("A coordinator's name that would close its mark reads back whole")
  func coordinatorNameClosingTheMark() throws {
    let text = CoordinationPolicy.fromCoordinator("Rebase.", coordinatorName: "Plan ”] V2")
    let message = try #require(RelayedMessage(text))
    #expect(message.sender == .coordinator("Plan ” ] V2"))
    #expect(message.body == "Rebase.")
  }

  @Test("A coordinator's message without words is still the coordinator's")
  func emptyCoordinatorMessage() throws {
    let message = try #require(
      RelayedMessage(CoordinationPolicy.fromCoordinator("  ", coordinatorName: "Plan")))
    #expect(message.sender == .coordinator("Plan"))
    #expect(message.body.isEmpty)
  }

  @Test("Quotes in a wake-up's reason name no child, and a question's indent is not code")
  func freeText() throws {
    let news = CoordinationInbox.message(for: [
      .wake("check “deploy” then ping", at: .now),
      CoordinationEvent(
        childID: childID, childName: "V2", kind: .awaitingUser("Choose one:\n\n    A) keep"),
        date: .now),
    ])
    let message = try #require(RelayedMessage(news))
    #expect(message.children == ["V2"])
    #expect(message.body.hasSuffix("\n\n" + #"A\) keep\. It is the user\'s to answer\."#))
  }

  @Test func theUsersWordsAreNotRelayed() {
    #expect(RelayedMessage("Fix the tests") == nil)
    #expect(RelayedMessage("[Coordinator] not a mark") == nil)
    // The mark pasted by the user, without the news it titles.
    #expect(RelayedMessage("[Vibe Manager] why did you say that?") == nil)
    #expect(RelayedMessage(CoordinatorInstructions.turnedOn + "\n\nPlan milestone V2") == nil)
    // Files alone, sent once coordination was turned on.
    #expect(RelayedMessage(CoordinatorInstructions.turnedOn + "\n\n") == nil)
    #expect(RelayedMessage(CoordinatorInstructions.turnedOff) == nil)
    let file = MessageAttachment.file(URL(fileURLWithPath: "/tmp/a.png"), id: "f")
    #expect(
      RelayedMessage(
        CoordinationPolicy.fromCoordinator("Look.", coordinatorName: "V2"), attachments: [file])
        == nil)
  }

  @Test("A coordinator's message ending with a path the reader joined is still the coordinator's")
  func endingWithAPath() throws {
    let text = CoordinationPolicy.fromCoordinator(
      "Implement the plan in /tmp/PLAN.md", coordinatorName: "Plan")
    let joined = MessageAttachment.file(
      URL(fileURLWithPath: "/tmp/PLAN.md"), id: "c/file-0", isWrittenInText: true)
    let message = try #require(RelayedMessage(text, attachments: [joined]))
    #expect(message.sender == .coordinator("Plan"))
    #expect(message.body.contains("PLAN"))
  }

  @Test("A coordinator's message is not the source of a reply of the user's")
  func notRepliedTo() {
    let date = Date(timeIntervalSince1970: 1_000)
    let blocks: [ConversationBlock] = [
      .entry(
        ConversationEntry(
          id: "c", date: date,
          content: .userPrompt(
            CoordinationPolicy.fromCoordinator("Rebase on main.", coordinatorName: "V2"),
            attachments: []))),
      .entry(
        ConversationEntry(
          id: "u", date: date, content: .userPrompt("Rebase on main.", attachments: []))),
    ]
    let quote = ReplyQuote(excerpt: "Rebase on main.", author: .user, date: date)
    #expect(ReplyLinks.source(of: quote, in: blocks[...]) == "u")
    #expect(ReplyLinks.source(of: quote, in: blocks[..<1]) == nil)
  }
}
