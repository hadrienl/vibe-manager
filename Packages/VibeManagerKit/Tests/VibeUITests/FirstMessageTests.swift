import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI
@testable import VibeUI

/// A session created with files joined to its prompt sends its first message from its
/// conversation's composer once the agent is ready, as the user would (#291).
@MainActor
@Suite("The first message of a session created with files", .serialized)
struct FirstMessageTests {
  private static let provider = WorkspaceProvider()

  private struct Fixture {
    let model: AppModel
    let conversation: ConversationModel
    let session: WorkSession
    let folder: URL
  }

  private func waitUntil(_ condition: () -> Bool) async {
    // A state is waited for, not a deadline: the bound only stops a test that would hang.
    for _ in 0..<6000 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  /// A running session shown in conversation, its transcript not yet written.
  private func running() async throws -> Fixture {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("FirstMessageTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let session = WorkSession(
      name: "Files",
      agent: SessionAgentConfiguration(providerID: "stub"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      closedAt: Date(timeIntervalSince1970: 1),
      repositories: [RepositoryContext(path: folder.path)]
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
      for: AgentLaunchRequest(workingDirectoryPath: folder.path))
    await launcher.launch(session: session, plan: plan)
    await model.reload()
    model.select(session.id)
    await waitUntil { model.pane(for: session.id)?.status == .running }
    model.setPresentation(.conversation, of: session.id)
    let conversation = model.conversations.show(session)
    conversation.follow(
      AsyncStream { continuation in
        continuation.yield(
          ConversationSnapshot(availability: .notYetWritten(providerName: "Stub Agent")))
      })
    await waitUntil { conversation.snapshot.availability != .loading }
    return Fixture(model: model, conversation: conversation, session: session, folder: folder)
  }

  @Test("It waits in the composer until the agent is known to run, then is sent from it")
  func sentOnceReady() async throws {
    let fixture = try await running()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let file = fixture.folder.appendingPathComponent("Capture d’écran.png")
    let message = PromptSubmission(text: "yeah", attachments: [file])

    fixture.model.sendFirstMessage(message, to: fixture.session)

    #expect(fixture.conversation.draft == "yeah")
    #expect(fixture.conversation.attachments == [file])
    // The process has not been seen starting: nothing is typed yet.
    try await Task.sleep(for: .milliseconds(300))
    #expect(fixture.conversation.echoes.isEmpty)

    fixture.model.activities[fixture.session.id] = AgentActivityState(source: .structured)
    await waitUntil { !fixture.conversation.echoes.isEmpty }

    #expect(fixture.conversation.echoes.count == 1)
    #expect(fixture.conversation.echoes.first?.attachmentCount == 1)
    #expect(fixture.conversation.draft.isEmpty)
    #expect(fixture.conversation.attachments.isEmpty)
  }

  @Test("A composer the user changed meanwhile is left to them")
  func leftToTheUser() async throws {
    let fixture = try await running()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let file = fixture.folder.appendingPathComponent("a.txt")

    fixture.model.sendFirstMessage(
      PromptSubmission(text: "yeah", attachments: [file]), to: fixture.session)
    fixture.conversation.draft = "yeah, and more"
    fixture.model.activities[fixture.session.id] = AgentActivityState(source: .structured)
    try await Task.sleep(for: .milliseconds(400))

    #expect(fixture.conversation.echoes.isEmpty)
    #expect(fixture.conversation.draft == "yeah, and more")
    #expect(fixture.conversation.attachments == [file])
  }
}
