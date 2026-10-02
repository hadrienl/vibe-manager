import AppKit
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// What the palette would notify, recorded.
@MainActor
private final class IdentityNotifier: RequestNotifying {
  private(set) var posted: [RequestNotification] = []
  func post(_ notification: RequestNotification) { posted.append(notification) }
  func remove(_ ids: [AgentRequestID]) {}
  func setBadge(_ count: Int?) {}
  func isAuthorized() async -> Bool? { true }
}

private struct FolderIcons: ProjectIconFinding {
  let icon: ProjectIcon?
  func icon(inFolder path: String) async -> ProjectIcon? { icon }
}

@MainActor
@Suite("Renaming a session and changing its icon (#183)", .serialized, .timeLimit(.minutes(2)))
struct SessionIdentityTests {
  private static let provider = WorkspaceProvider()
  private let iconID = SessionIconID(sha256: String(repeating: "c", count: 64))!

  private func session(_ name: String, path: String) -> WorkSession {
    WorkSession(
      name: name,
      agent: SessionAgentConfiguration(
        providerID: "stub", resumeIdentifier: "conversation-\(name)"),
      appearance: SessionAppearance(symbolName: "bolt", colorHex: "#0B63E5"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      closedAt: Date(timeIntervalSince1970: 1),
      repositories: [RepositoryContext(path: path)]
    )
  }

  private struct Workspace {
    let model: AppModel
    let repository: WorkspaceRepository
    let supervisor: WorkspaceSupervisor
    let running: WorkSession
    let other: WorkSession
  }

  /// Two sessions, the first one's agent running.
  private func workspace(projectIcon: ProjectIcon? = nil) async throws -> Workspace {
    let path = NSTemporaryDirectory().appending("vibe-identity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let running = session("Running", path: path)
    let other = session("Other", path: path)
    let repository = WorkspaceRepository(sessions: [running, other])
    let registry = WorkspaceRegistry(providers: [Self.provider])
    let supervisor = WorkspaceSupervisor()
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry, viewportTimeout: .zero)
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher,
      projectIcons: FolderIcons(icon: projectIcon))
    let plan = try await Self.provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: path))
    await launcher.launch(session: running, plan: plan)
    await model.load()
    model.select(running.id)
    await waitUntil("the agent runs") { model.pane(for: running.id)?.status == .running }
    return Workspace(
      model: model, repository: repository, supervisor: supervisor, running: running,
      other: other)
  }

  @Test("Renaming a running session touches neither its terminal nor its agent")
  func renameLeavesTheAgentAlone() async throws {
    let workspace = try await workspace()
    let model = workspace.model
    let id = workspace.running.id
    let pane = try #require(model.pane(for: id))
    let starts = await workspace.supervisor.startCount
    let before = try #require(await workspace.repository.session(id: id))
    let terminal = try #require(
      await workspace.supervisor.session(for: id.agentTerminal) as? WorkspaceTerminal)

    model.beginRename(id, in: .sidebar)
    #expect(model.renaming == SessionIdentityEditing(sessionID: id, place: .sidebar))
    let refusal = await model.commitRename(id, to: "  Fix the sign-in  ")

    #expect(refusal == nil)
    #expect(model.renaming == nil)
    #expect(model.sessions.first { $0.id == id }?.name == "Fix the sign-in")
    let stored = try #require(await workspace.repository.session(id: id))
    #expect(stored.name == "Fix the sign-in")
    #expect(stored.agent?.resumeIdentifier == "conversation-Running")
    #expect(stored.updatedAt == before.updatedAt)
    #expect(stored.rank == before.rank)
    #expect(stored.repositories == workspace.running.repositories)
    // The same terminal, the same process, and not a byte sent to it.
    #expect(model.pane(for: id) === pane)
    #expect(pane.status == .running)
    #expect(await workspace.supervisor.startCount == starts)
    #expect(await terminal.written.isEmpty)
  }

  @Test("A refused name keeps the field open and the old name")
  func refusedName() async throws {
    let workspace = try await workspace()
    let model = workspace.model
    let id = workspace.running.id
    model.beginRename(id, in: .sidebar)

    #expect(await model.commitRename(id, to: "   ") == .nameMissing)
    #expect(await model.commitRename(id, to: String(repeating: "a", count: 121)) == .nameTooLong)

    #expect(model.renaming?.sessionID == id)
    #expect(model.sessions.first { $0.id == id }?.name == "Running")
    #expect(await workspace.repository.session(id: id)?.name == "Running")
    #expect(!model.canUndoSidebarChange)
  }

  @Test("The window's title, ⌘1…⌘9, Open Quickly and the notifications follow the new name")
  func everythingFollows() async throws {
    let workspace = try await workspace()
    let model = workspace.model
    let id = workspace.running.id
    let (notifier, request) = notifyRequest(of: id, in: model)
    #expect(notifier.posted.count == 1)

    await model.commitRename(id, to: "Fix the sign-in")

    #expect(model.windowTitle.sessionName == "Fix the sign-in")
    #expect(model.displayedSessions.map(\.name).contains("Fix the sign-in"))
    #expect(model.allPendingRequests.first?.session.name == "Fix the sign-in")
    // Posted again under the new name, without a sound.
    let reposted = try #require(notifier.posted.last)
    #expect(notifier.posted.count == 2)
    #expect(reposted.id == request)
    #expect(reposted.title.hasPrefix("Fix the sign-in"))
    #expect(reposted.isSilent)
    #expect(!notifier.posted[0].isSilent)

    model.presentQuickOpen()
    model.quickOpen.setText("sign-in")
    await waitUntil("Open Quickly finds the new name") {
      model.quickOpen.answer?.query.text == "sign-in"
        && model.quickOpen.results.contains { $0.sessionID == id }
    }
  }

  /// A request of the session, notified while the application is in the background.
  private func notifyRequest(of id: SessionID, in model: AppModel) -> (
    IdentityNotifier, AgentRequestID
  ) {
    let notifier = IdentityNotifier()
    model.requestNotifier = notifier
    model.applicationWillResignActive()
    let request = AgentRequestID(sessionID: id, key: "make")
    var state = AgentActivityState(source: .structured)
    state.activity = .awaitingUser(.approval)
    state.requests.append(
      AgentRequest(
        id: request, receivedAt: Date(timeIntervalSince1970: 10), kind: .approval,
        content: .permission(AgentToolPermission(tool: .shell, toolName: "Bash", subject: "make")),
        reference: AgentToolReference(tool: "Bash", subject: "make"), isShown: true))
    model.activities[id] = state
    model.requestAnswering[request] = .fromPalette([.allowOnce, .deny])
    model.requestsDidChange()
    return (notifier, request)
  }

  @Test("A new icon, or notifications turned off, posts nothing again")
  func notificationsLeftAlone() async throws {
    let workspace = try await workspace()
    let model = workspace.model
    let id = workspace.running.id
    let (notifier, _) = notifyRequest(of: id, in: model)
    #expect(notifier.posted.count == 1)

    model.beginAppearanceEditing(id, in: .sidebar)
    try #require(model.appearanceEditor).pickSymbol("flask")
    model.endAppearanceEditing()
    await waitUntil("the icon is written") {
      await workspace.repository.session(id: id)?.appearance.symbolName == "flask"
    }
    await model.reload()
    #expect(notifier.posted.count == 1)

    model.notifiesRequests = false
    await model.commitRename(id, to: "Quiet")
    #expect(notifier.posted.count == 1)
  }

  @Test("⌘Z in a text being typed undoes the typing, not the last rename")
  func textKeepsItsUndo() {
    #expect(AppModel.isEditingText(NSTextView()))
    #expect(!AppModel.isEditingText(NSTableView()))
    #expect(!AppModel.isEditingText(nil))
  }

  @Test("The icon is previewed while it is chosen, and Escape leaves the session as it was")
  func previewAndCancel() async throws {
    let workspace = try await workspace()
    let model = workspace.model
    let session = workspace.running

    model.beginAppearanceEditing(session.id, in: .sidebar)
    let editor = try #require(model.appearanceEditor)
    editor.pickSymbol("flask")
    #expect(model.displayedAppearance(of: session).symbolName == "flask")
    #expect(model.sessions.first { $0.id == session.id }?.appearance == session.appearance)

    model.cancelAppearanceEditing()
    #expect(model.appearanceEditor == nil)
    #expect(model.displayedAppearance(of: session) == session.appearance)
    #expect(await workspace.repository.session(id: session.id)?.appearance == session.appearance)
    #expect(!model.canUndoSidebarChange)
  }

  @Test("Closing the popover keeps the icon chosen, as one change for ⌘Z")
  func commitAppearance() async throws {
    let workspace = try await workspace()
    let model = workspace.model
    let id = workspace.running.id

    model.beginAppearanceEditing(id, in: .sidebar)
    let editor = try #require(model.appearanceEditor)
    editor.pickSymbol("flask")
    editor.pickColor("#1E7F4D")
    model.endAppearanceEditing()

    let chosen = SessionAppearance(symbolName: "flask", colorHex: "#1E7F4D")
    #expect(model.sessions.first { $0.id == id }?.appearance == chosen)
    await waitUntil("the icon is written") {
      await workspace.repository.session(id: id)?.appearance == chosen
    }
    await waitUntil("the change can be undone") { model.canUndoSidebarChange }

    await model.undoSidebarChange()
    #expect(await workspace.repository.session(id: id)?.appearance == workspace.running.appearance)
    #expect(!model.canUndoSidebarChange)
    #expect(model.canRedoSidebarChange)
  }

  @Test("A theme is previewed in the conversation while it is chosen; Escape writes nothing (#274)")
  func themePreviewAndCancel() async throws {
    let workspace = try await workspace()
    let model = workspace.model
    let session = workspace.running

    model.beginThemeEditing(session.id, in: .inspector)
    model.previewTheme("night")
    #expect(model.displayedConversationTheme(of: session) == "night")
    #expect(model.displayedConversationTheme(of: workspace.other) == nil)
    #expect(model.sessions.first { $0.id == session.id }?.conversationTheme == nil)

    model.cancelThemeEditing()
    #expect(model.themeEditing == nil)
    #expect(model.displayedConversationTheme(of: session) == nil)
    #expect(await workspace.repository.session(id: session.id)?.conversationTheme == nil)
    #expect(!model.canUndoSidebarChange)
  }

  @Test("Closing the theme popover keeps the theme chosen, as one change for ⌘Z")
  func commitTheme() async throws {
    let workspace = try await workspace()
    let model = workspace.model
    let id = workspace.running.id
    let updatedAt = await workspace.repository.session(id: id)?.updatedAt

    model.beginThemeEditing(id, in: .sidebar)
    model.previewTheme("paper")
    model.previewTheme("night")
    model.endThemeEditing()

    #expect(model.sessions.first { $0.id == id }?.conversationTheme == "night")
    await waitUntil("the theme is written") {
      await workspace.repository.session(id: id)?.conversationTheme == "night"
    }
    await waitUntil("the change can be undone") { model.canUndoSidebarChange }
    #expect(await workspace.repository.session(id: id)?.updatedAt == updatedAt)

    await model.undoSidebarChange()
    #expect(await workspace.repository.session(id: id)?.conversationTheme == nil)
    #expect(!model.canUndoSidebarChange)
  }

  @Test("Revert to Default Icon gives what a creation would: the folder's icon, kept on disk")
  func revertToDefault() async throws {
    let icon = ProjectIcon(id: iconID, pngData: Data([0x89, 0x50]))
    let workspace = try await workspace(projectIcon: icon)
    let model = workspace.model
    let id = workspace.running.id

    model.beginAppearanceEditing(id, in: .sidebar)
    let editor = try #require(model.appearanceEditor)
    await waitUntil("the folder has been looked at") { editor.defaultAppearance != nil }
    #expect(editor.projectIconID == iconID)
    editor.revertToDefault()
    #expect(editor.isDefault)
    model.endAppearanceEditing()

    let expected = SessionAppearanceCatalog.defaultAppearance(
      forName: "Running", projectIcon: iconID)
    await waitUntil("the default icon is written") {
      await workspace.repository.session(id: id)?.appearance == expected
    }
    #expect(await model.iconStore.pngData(for: iconID) == icon.pngData)
  }

  @Test("⌘Z undoes the last rename, ⇧⌘Z redoes it, and neither goes over a later change")
  func undoRedo() async throws {
    let workspace = try await workspace()
    let model = workspace.model
    let id = workspace.running.id

    await model.commitRename(id, to: "First")
    await model.commitRename(id, to: "Second")
    await model.undoSidebarChange()
    #expect(await workspace.repository.session(id: id)?.name == "First")
    await model.redoSidebarChange()
    #expect(await workspace.repository.session(id: id)?.name == "Second")

    await model.undoSidebarChange()
    // Changed behind the history's back: undoing "First" would lose it.
    _ = try await workspace.repository.mutate(id: id) { $0.name = "Elsewhere" }
    await model.reload()
    await model.undoSidebarChange()
    #expect(await workspace.repository.session(id: id)?.name == "Elsewhere")
  }

  @Test("From the menu bar, the row is edited when the sidebar shows it, the inspector otherwise")
  func editingPlace() async throws {
    let workspace = try await workspace()
    let model = workspace.model
    model.layout.windowWidthChanged(to: 1_400)
    model.layout.setSidebarVisible(true)
    #expect(model.layout.columns.isSidebarVisible)
    let shown = try #require(model.displayedSessions.first)
    model.beginRename(shown.id)
    #expect(model.renaming?.place == .sidebar)
    model.cancelRename()

    // A session the sidebar does not show — another column — is renamed in the inspector.
    let hidden = try #require(
      [workspace.running, workspace.other].first { session in
        !model.displayedSessions.contains { $0.id == session.id }
      })
    model.beginRename(hidden.id)
    #expect(model.renaming?.place == .inspector)
    #expect(model.selectedSessionID == hidden.id)
    model.cancelRename()

    model.layout.setSidebarVisible(false)
    model.beginRename(workspace.other.id)
    #expect(model.renaming?.place == .inspector)
    // The inspector shows the session on screen: it is brought there.
    #expect(model.selectedSessionID == workspace.other.id)
  }

  @Test("Only a double-click renames from the list: Return and a single click do not")
  func doubleClickOnly() throws {
    func mouse(_ type: NSEvent.EventType, clicks: Int) -> NSEvent? {
      NSEvent.mouseEvent(
        with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
    }
    let returnKey = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
      keyCode: 36)
    #expect(SessionSidebar.isDoubleClick(mouse(.leftMouseDown, clicks: 2)))
    #expect(!SessionSidebar.isDoubleClick(mouse(.leftMouseDown, clicks: 1)))
    #expect(!SessionSidebar.isDoubleClick(returnKey))
    #expect(!SessionSidebar.isDoubleClick(nil))
  }

  @Test("A double-click on the badge changes the icon, anywhere else on the row renames")
  func badgeOrName() throws {
    func click(at x: CGFloat) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: NSPoint(x: x, y: 10), modifierFlags: [], timestamp: 0,
          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
    }
    #expect(SessionSidebar.isOnBadge(try click(at: 30), badgeTrailingEdge: 52))
    #expect(SessionSidebar.isOnBadge(try click(at: 52), badgeTrailingEdge: 52))
    #expect(!SessionSidebar.isOnBadge(try click(at: 80), badgeTrailingEdge: 52))
    // Before the badges have been measured, a double-click renames.
    #expect(!SessionSidebar.isOnBadge(try click(at: 30), badgeTrailingEdge: nil))
  }
}
