import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI
@testable import VibeUI

@MainActor
@Suite("Giving the keyboard to the session on screen (#105)")
struct SessionFocusTests {
  private static let provider = WorkspaceProvider()

  private func session(_ name: String, path: String) -> WorkSession {
    WorkSession(
      name: name,
      agent: SessionAgentConfiguration(providerID: "stub"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      closedAt: Date(timeIntervalSince1970: 1),
      repositories: [RepositoryContext(path: path)]
    )
  }

  /// Two sessions whose agent writes a conversation the view can read; the first one running.
  private func workspace() async throws -> (AppModel, running: WorkSession, stopped: WorkSession) {
    let path = NSTemporaryDirectory().appending("vibe-focus-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let running = session("Running", path: path)
    let stopped = session("Stopped", path: path)
    let repository = WorkspaceRepository(sessions: [running, stopped])
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
    await launcher.launch(session: running, plan: plan)
    await model.reload()
    model.select(running.id)
    await waitUntil { model.pane(for: running.id)?.status == .running }
    return (model, running, stopped)
  }

  private func waitUntil(_ condition: () async -> Bool) async {
    // A state is waited for, not a deadline: the bound only stops a test that would hang.
    for _ in 0..<6000 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test("In the terminal, the terminal takes the keyboard, as it always has")
  func terminal() async throws {
    let (model, running, _) = try await workspace()
    model.setPresentation(.terminal, of: running.id)
    let pane = try #require(model.pane(for: running.id))
    let before = pane.focusRequest

    #expect(model.focusSession())

    #expect(pane.focusRequest == before + 1)
    #expect(model.conversations.existingModel(for: running.id) == nil)
  }

  @Test("In the conversation view, the composer takes it, even before its model exists")
  func conversation() async throws {
    let (model, running, _) = try await workspace()
    model.setPresentation(.conversation, of: running.id)
    let pane = try #require(model.pane(for: running.id))
    let before = pane.focusRequest
    #expect(model.conversations.existingModel(for: running.id) == nil)

    #expect(model.focusSession())

    // The view readies the model once it is on screen: the request is waiting for it.
    let conversation = model.conversations.show(running)
    #expect(conversation.takePendingFocusRequest())
    #expect(pane.focusRequest == before)

    #expect(model.focusSession())
    #expect(conversation.focusComposerRequest == 2)
  }

  @Test("⌘P to a stopped session in the conversation view leaves the keyboard on its row")
  func stopped() async throws {
    let (model, _, stopped) = try await workspace()
    model.setPresentation(.conversation, of: stopped.id)
    let conversation = model.conversations.show(stopped)
    _ = conversation.takePendingFocusRequest()
    let requests = conversation.focusComposerRequest
    let sidebar = model.sidebarFocusRequest

    model.goToSession(stopped.id)

    #expect(model.selectedSessionID == stopped.id)
    #expect(model.sidebarFocusRequest == sidebar + 1)
    #expect(conversation.focusComposerRequest == requests)
    #expect(!conversation.takePendingFocusRequest())
  }

  @Test("⌘P to a stopped session in the terminal leaves the keyboard on its row alone")
  func stoppedTerminal() async throws {
    let (model, _, stopped) = try await workspace()
    model.setPresentation(.terminal, of: stopped.id)
    let sidebar = model.sidebarFocusRequest
    let pane = model.pane(for: stopped.id)
    let before = pane?.focusRequest

    model.goToSession(stopped.id)

    #expect(model.sidebarFocusRequest == sidebar + 1)
    #expect(model.pane(for: stopped.id)?.focusRequest == before)
  }

  @Test("Nothing takes the keyboard from Open Quickly")
  func quickOpen() async throws {
    let (model, running, _) = try await workspace()
    model.setPresentation(.conversation, of: running.id)
    let conversation = model.conversations.show(running)
    _ = conversation.takePendingFocusRequest()
    model.presentQuickOpen()

    #expect(!model.canClaimKeyboard)
    #expect(!model.composerClaimsKeyboardOnActivation)
    #expect(!model.focusSession())
    #expect(!conversation.takePendingFocusRequest())
  }

  @Test("Walking the sidebar with the arrows keeps the keyboard there; Return hands it over")
  func sidebarArrows() async throws {
    let (model, running, stopped) = try await workspace()
    #expect(model.composerClaimsKeyboardOnActivation)

    model.selectFromList([stopped.id], byKeyboard: true)
    #expect(model.selectedSessionID == stopped.id)
    #expect(!model.composerClaimsKeyboardOnActivation)
    model.selectFromList([running.id], byKeyboard: true)
    #expect(!model.composerClaimsKeyboardOnActivation)

    // Return on the row.
    #expect(model.focusSession())
    #expect(model.composerClaimsKeyboardOnActivation)

    // Any other way to a session gives it the keyboard again.
    model.selectFromList([stopped.id], byKeyboard: true)
    model.selectFromList([running.id])
    #expect(model.composerClaimsKeyboardOnActivation)
    model.selectFromList([stopped.id], byKeyboard: true)
    model.goToSession(running.id)
    #expect(model.composerClaimsKeyboardOnActivation)
  }

  @Test("A request left waiting for a session the user moved away from is dropped")
  func movedAway() async throws {
    let (model, running, stopped) = try await workspace()
    model.setPresentation(.conversation, of: running.id)
    #expect(model.focusSession())

    model.select(stopped.id)

    #expect(model.conversations.show(running).focusComposerRequest == 0)
  }
}
