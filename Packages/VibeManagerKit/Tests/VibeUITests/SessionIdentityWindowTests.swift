import AppKit
import Foundation
import SwiftUI
import Testing
import VibeApplication
import VibeDomain
import VibeTerminalUI

@testable import VibeUI

/// ⌘Z and the field, in the real window — never put on screen (#183).
@MainActor
@Suite(
  "Renaming in the window: the field in the row, ⌘Z in the sidebar only", .serialized,
  .timeLimit(.minutes(2)))
struct SessionIdentityWindowTests {
  private static let provider = WorkspaceProvider()

  @MainActor private final class Workspace {
    let model: AppModel
    let repository: WorkspaceRepository
    let session: WorkSession
    let window: NSWindow
    let folder: String

    init(
      model: AppModel, repository: WorkspaceRepository, session: WorkSession, window: NSWindow,
      folder: String
    ) {
      self.model = model
      self.repository = repository
      self.session = session
      self.window = window
      self.folder = folder
    }

    /// The sidebar's list, as AppKit draws it: the one the keyboard monitor stands behind.
    var list: NSTableView? {
      Self.all(KeyboardDepartureMonitor.MonitorView.self, in: window.contentView).first?.list
    }

    var terminal: AccessibleTerminalView? {
      Self.all(AccessibleTerminalView.self, in: window.contentView).first { !$0.isHidden }
    }

    var nameFields: [NSTextField] {
      Self.all(NSTextField.self, in: window.contentView).filter {
        $0.isEditable && $0.stringValue == session.name
      }
    }

    func close() {
      window.contentView = nil
      window.close()
      try? FileManager.default.removeItem(atPath: folder)
    }

    static func all<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
      guard let view else { return [] }
      let own = (view as? T).map { [$0] } ?? []
      return own + view.subviews.flatMap { all(type, in: $0) }
    }
  }

  private func workspace() async throws -> Workspace {
    let folder = NSTemporaryDirectory().appending("vibe-identity-window-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let session = WorkSession(
      name: "Alpha",
      agent: SessionAgentConfiguration(providerID: "stub"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      closedAt: Date(timeIntervalSince1970: 1),
      repositories: [RepositoryContext(path: folder)]
    )
    let repository = WorkspaceRepository(sessions: [session])
    let registry = WorkspaceRegistry(providers: [Self.provider])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    let plan = try await Self.provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: folder))
    await launcher.launch(session: session, plan: plan)
    await model.load()
    model.select(session.id)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: RootView(model: model))
    return Workspace(
      model: model, repository: repository, session: session, window: window, folder: folder)
  }

  private static let undo = Selector(("undo:"))

  /// Whether something between the view and the window takes ⌘Z: the window's own undo manager
  /// does not count.
  private static func answersUndo(before window: NSWindow?, from view: NSView) -> Bool {
    var responder: NSResponder? = view
    while let current = responder, current !== window {
      if current.responds(to: undo) { return true }
      responder = current.nextResponder
    }
    return false
  }

  @Test("Rename turns the row's name into a field, which Escape closes")
  func fieldInTheRow() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    await waitUntil("the list") { workspace.list != nil }

    workspace.model.beginRename(workspace.session.id, in: .sidebar)
    await waitUntil("the name field") { !workspace.nameFields.isEmpty }

    workspace.model.cancelRename()
    await waitUntil("the field goes") { workspace.nameFields.isEmpty }
    #expect(workspace.model.sessions.first?.name == "Alpha")
  }

  @Test("⌘Z in the sidebar undoes a rename; in the terminal, it does not")
  func undoOnlyInTheSidebar() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    let model = workspace.model
    let id = workspace.session.id
    await waitUntil("the list and the terminal") {
      workspace.list != nil && workspace.terminal != nil
    }
    await model.commitRename(id, to: "Bravo")
    #expect(model.canUndoIdentityChange)

    let list = try #require(workspace.list)
    workspace.window.makeFirstResponder(list)
    // Once the sidebar has been drawn again with something to undo.
    await waitUntil("the sidebar answers ⌘Z") { Self.answersUndo(before: list.window, from: list) }

    // In the terminal, ⌘Z goes on to the window: the rename stays.
    let terminal = try #require(workspace.terminal)
    workspace.window.makeFirstResponder(terminal)
    #expect(!Self.answersUndo(before: workspace.window, from: terminal))
    _ = terminal.tryToPerform(Self.undo, with: nil)
    #expect(await workspace.repository.session(id: id)?.name == "Bravo")
    #expect(model.canUndoIdentityChange)

    workspace.window.makeFirstResponder(list)
    await waitUntil("the sidebar answers ⌘Z again") {
      Self.answersUndo(before: list.window, from: list)
    }
    #expect(list.tryToPerform(Self.undo, with: nil))
    await waitUntil("the rename is undone") {
      await workspace.repository.session(id: id)?.name == "Alpha"
    }
    #expect(model.sessions.first?.name == "Alpha")
  }
}
