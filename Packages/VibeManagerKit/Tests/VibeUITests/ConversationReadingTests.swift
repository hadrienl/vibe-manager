import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI
@testable import VibeUI

/// Reading the conversation from the keyboard and with VoiceOver (#227).
@MainActor
@Suite("Reading the conversation without a mouse (#227)")
struct ConversationReadingTests {
  private static let provider = WorkspaceProvider()

  /// A session whose agent writes a conversation the view can read, running and selected.
  private func workspace() async throws -> (AppModel, WorkSession) {
    let path = NSTemporaryDirectory().appending("vibe-reading-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let session = WorkSession(
      name: "Reading",
      agent: SessionAgentConfiguration(providerID: "stub"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      closedAt: Date(timeIntervalSince1970: 1),
      repositories: [RepositoryContext(path: path)]
    )
    let repository = WorkspaceRepository(sessions: [session])
    let registry = WorkspaceRegistry(providers: [Self.provider])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    model.connectConversations()
    model.conversations.readableAgents = [
      "stub": ConversationWorkspace.Agent(name: "Stub Agent", format: AgentPromptFormat())
    ]
    let plan = try await Self.provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: path))
    await launcher.launch(session: session, plan: plan)
    await model.reload()
    model.select(session.id)
    await waitUntil { model.pane(for: session.id)?.status == .running }
    return (model, session)
  }

  private func waitUntil(_ condition: () async -> Bool) async {
    // A state is waited for, not a deadline: the bound only stops a test that would hang.
    for _ in 0..<6000 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test("In a conversation, Read Last Output says the agent's last message, as plain text")
  func readsTheLastMessage() async throws {
    let (model, session) = try await workspace()
    model.setPresentation(.conversation, of: session.id)
    let conversation = model.conversations.show(session)
    conversation.received(
      ConversationSnapshot(
        entries: [
          ConversationEntry(id: "1", content: .agentText("An older answer.")),
          ConversationEntry(id: "2", content: .userPrompt("And now?", attachments: [])),
          ConversationEntry(
            id: "3", content: .agentText("**Done**: the tests pass.\n\n- one\n- two")),
          ConversationEntry(id: "4", content: .reasoning("thinking")),
        ],
        availability: .available))

    await model.readLastOutput()

    #expect(Announcer.lastAnnouncement == "Done: the tests pass.\none\ntwo")
  }

  @Test("In a conversation where the agent has said nothing, Read Last Output says so")
  func nothingSaidYet() async throws {
    let (model, session) = try await workspace()
    model.setPresentation(.conversation, of: session.id)
    model.conversations.show(session)
      .received(ConversationSnapshot(entries: [], availability: .available))

    await model.readLastOutput()

    #expect(Announcer.lastAnnouncement == "The agent has said nothing yet.")
  }

  @Test("Page Up, Page Down and End are asked of the conversation, twice in a row too")
  func pageRequests() {
    let model = ConversationModel(sessionID: SessionID())
    let before = model.scrollToBottomRequest

    model.scrollPage(.up)
    model.scrollPage(.up)
    #expect(model.pageRequest == ConversationModel.PageRequest(page: .up, count: 2))
    model.scrollPage(.down)
    #expect(model.pageRequest.page == .down)
    model.jumpToBottom()
    #expect(model.scrollToBottomRequest == before + 1)
  }

  @Test(
    "A page moves by the height read below the toolbar, never past either end",
    arguments: [true, false])
  func pageOrigin(isFlipped: Bool) {
    // A 400-point view whose top 52 points lie under the toolbar.
    let insets = isFlipped ? (top: 52.0, bottom: 0.0) : (top: 0.0, bottom: 52.0)
    func next(_ page: ConversationModel.Page, from y: Double) -> Double {
      ConversationPager.origin(
        after: page, from: y, viewHeight: 400, documentHeight: 2000, insets: insets,
        overlap: 40, isFlipped: isFlipped)
    }
    // Flipped, the end of the conversation is at the largest origin; unflipped, at the smallest.
    let down = isFlipped ? 308.0 : -308.0
    #expect(next(.down, from: 800) == 800 + down)
    #expect(next(.up, from: 800) == 800 - down)
    // No line skipped: what a page shows first under the toolbar was still in view before.
    let readTop = 800 + 52.0
    let readBottom = 800 + 400.0
    #expect(isFlipped ? next(.down, from: 800) + 52 < readBottom : true)
    #expect(isFlipped ? next(.up, from: 800) + 400 > readTop : true)
    // The ends: the first message just below the toolbar, the last one at the bottom.
    #expect(next(isFlipped ? .up : .down, from: 100) == -52)
    #expect(next(isFlipped ? .down : .up, from: 1500) == 1600)
  }
}
