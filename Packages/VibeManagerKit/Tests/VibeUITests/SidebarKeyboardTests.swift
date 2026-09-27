import AppKit
import Foundation
import SwiftUI
import Testing
import VibeApplication
import VibeDomain
import VibeTerminalUI

@testable import VibeUI

/// A selection of several sessions is for the sidebar's commands only: once the keyboard is
/// somewhere else, ⌘W and the Session menu act on the session on screen alone (#128).
@MainActor
@Suite(
  "The keyboard leaving the sidebar shrinks its selection", .serialized, .timeLimit(.minutes(1)))
struct SidebarKeyboardTests {
  private static let provider = WorkspaceProvider()

  /// Three running sessions, their terminals mounted by the real window's content.
  @MainActor private final class Workspace {
    let model: AppModel
    let sessions: [WorkSession]
    let window: NSWindow

    init(model: AppModel, sessions: [WorkSession], window: NSWindow) {
      self.model = model
      self.sessions = sessions
      self.window = window
    }

    var ids: [SessionID] { sessions.map(\.id) }

    /// The sidebar's list, as AppKit draws it: the list along the window's left edge, the
    /// inspector having its own. None until the window is laid out.
    var list: NSTableView? {
      Self.all(NSTableView.self, in: window.contentView).first {
        let frame = $0.convert($0.bounds, to: nil)
        return !frame.isEmpty && frame.minX == 0
      }
    }

    /// The terminal of a session once it is on screen: the others stay mounted, hidden. Found by
    /// what VoiceOver calls it, which names its session.
    func shownTerminal(of session: WorkSession) -> AccessibleTerminalView? {
      Self.all(AccessibleTerminalView.self, in: window.contentView).first {
        !$0.isHidden && $0.accessibilityTitle.contains(session.name)
      }
    }

    var keyboardIsInTheList: Bool {
      guard let list, let responder = window.firstResponder as? NSView else { return false }
      return responder === list || responder.isDescendant(of: list)
    }

    func close() {
      window.contentView = nil
      window.close()
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
      guard let view else { return [] }
      if let match = view as? T { return [match] }
      return view.subviews.flatMap { all(type, in: $0) }
    }
  }

  private func workspace() async throws -> Workspace {
    let path = NSTemporaryDirectory().appending("vibe-sidebar-keyboard-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let sessions = (1...3).map { index in
      WorkSession(
        name: ["Alpha", "Bravo", "Charlie"][index - 1],
        agent: SessionAgentConfiguration(providerID: "stub"),
        status: .closed,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: TimeInterval(400 - index)),
        closedAt: Date(timeIntervalSince1970: 1),
        repositories: [RepositoryContext(path: path)]
      )
    }
    let repository = WorkspaceRepository(sessions: sessions)
    let registry = WorkspaceRegistry(providers: [Self.provider])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    let plan = try await Self.provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: path))
    for session in sessions {
      await launcher.launch(session: session, plan: plan)
    }
    await model.reload()

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    // Owned by this test, not by AppKit: a window made in code releases itself when closed.
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: RootView(model: model))
    return Workspace(model: model, sessions: sessions, window: window)
  }

  /// A state is waited for, not a deadline: the suite's time limit stops a test that never gets
  /// there.
  private func waitUntil(_ condition: () -> Bool) async throws {
    while !condition() {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// What a click on a row, then ⌘-clicks on the two others, do: the list takes the keyboard,
  /// then reports each selection it draws.
  private func selectAll(in workspace: Workspace) async throws {
    let model = workspace.model
    let sessions = workspace.sessions
    model.select(sessions[0].id)
    try await waitUntil { workspace.list != nil && workspace.shownTerminal(of: sessions[0]) != nil }
    let list = try #require(workspace.list)
    for count in 2...3 {
      workspace.window.makeFirstResponder(list)
      model.selectFromList(Set(workspace.ids.prefix(count)))
      // The session clicked is on screen once its terminal is: shown in the update that would
      // hand it the keyboard, if anything did.
      try await waitUntil { workspace.shownTerminal(of: sessions[count - 1]) != nil }
    }
  }

  @Test("⌘-clicking rows keeps the keyboard in the list, and the selection with it")
  func selectingKeepsTheKeyboard() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }

    try await selectAll(in: workspace)

    #expect(workspace.keyboardIsInTheList)
    #expect(Set(workspace.model.commandTargets) == Set(workspace.ids))
  }

  @Test("A click in the terminal leaves the Session menu and ⌘W to the session on screen")
  func terminalTakesTheKeyboard() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    try await selectAll(in: workspace)
    let model = workspace.model
    #expect(model.hasMultipleSelection)

    let terminal = try #require(workspace.shownTerminal(of: workspace.sessions[2]))
    workspace.window.makeFirstResponder(terminal)
    try await waitUntil { !model.hasMultipleSelection }

    #expect(model.selectedSessionID == workspace.ids[2])
    #expect(model.commandTargets == [workspace.ids[2]])
  }

  @Test("Any AppKit view taking the keyboard shrinks the selection: the notes, the web view")
  func anyViewTakesTheKeyboard() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    try await selectAll(in: workspace)
    let model = workspace.model

    // Stands for the notes' text view, the web view, the composer: none is the list.
    let field = NSTextView(frame: NSRect(x: 1000, y: 400, width: 100, height: 20))
    let content = try #require(workspace.window.contentView)
    content.addSubview(field)
    workspace.window.makeFirstResponder(field)
    try await waitUntil { !model.hasMultipleSelection }

    #expect(model.commandTargets == [workspace.ids[2]])
  }
}
