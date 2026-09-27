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
  "The keyboard leaving the sidebar shrinks its selection", .serialized, .timeLimit(.minutes(2)))
struct SidebarKeyboardTests {
  private static let provider = WorkspaceProvider()

  /// Three running sessions, their terminals mounted by the real window's content.
  @MainActor private final class Workspace {
    let model: AppModel
    let sessions: [WorkSession]
    let window: NSWindow
    let folder: String

    init(model: AppModel, sessions: [WorkSession], window: NSWindow, folder: String) {
      self.model = model
      self.sessions = sessions
      self.window = window
      self.folder = folder
    }

    var ids: [SessionID] { sessions.map(\.id) }

    /// What watches the keyboard for the sidebar.
    var monitor: KeyboardDepartureMonitor.MonitorView? {
      Self.all(KeyboardDepartureMonitor.MonitorView.self, in: window.contentView).first
    }

    /// The sidebar's list, as AppKit draws it: the one the monitor stands behind.
    var list: NSTableView? { monitor?.list }

    /// The sidebar's search field.
    var searchField: NSSearchField? {
      Self.all(NSSearchField.self, in: window.contentView).first
    }

    /// The terminal of a session once it is on screen: the others stay mounted, hidden. Found by
    /// what VoiceOver calls it, which names its session.
    func shownTerminal(of session: WorkSession) -> AccessibleTerminalView? {
      terminals.first { !$0.isHidden && $0.accessibilityTitle.contains(session.name) }
    }

    var keyboardIsInTheList: Bool {
      guard let list, let responder = window.firstResponder as? NSView else { return false }
      return responder.isDescendant(of: list)
    }

    /// What a failed wait reports: enough to tell which part of the window never got there.
    var state: String {
      let tables = Self.all(NSTableView.self, in: window.contentView)
        .map { "\($0.convert($0.bounds, to: nil))" }
      let shown = terminals.map { "\($0.isHidden ? "hidden" : "shown") \($0.accessibilityTitle)" }
      return """
        monitor: \(monitor != nil), list: \(list.map { "\($0.numberOfRows) rows" } ?? "none"), \
        tables: \(tables), terminals: \(shown), \
        first responder: \(window.firstResponder.map { "\(type(of: $0))" } ?? "none"), \
        selection: \(model.selectedSessionIDs.count), \
        on screen: \(sessions.first { $0.id == model.selectedSessionID }?.name ?? "none")
        """
    }

    func close() {
      window.contentView = nil
      window.close()
      try? FileManager.default.removeItem(atPath: folder)
    }

    private var terminals: [AccessibleTerminalView] {
      Self.all(AccessibleTerminalView.self, in: window.contentView)
    }

    static func all<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
      guard let view else { return [] }
      if let match = view as? T { return [match] }
      return view.subviews.flatMap { all(type, in: $0) }
    }
  }

  private struct NeverReached: Error, CustomStringConvertible {
    let description: String
  }

  private func workspace() async throws -> Workspace {
    let folder = NSTemporaryDirectory().appending("vibe-sidebar-keyboard-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let sessions = ["Alpha one", "Bravo two", "Charlie two"].enumerated().map { index, name in
      WorkSession(
        name: name,
        agent: SessionAgentConfiguration(providerID: "stub"),
        status: .closed,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: TimeInterval(400 - index)),
        closedAt: Date(timeIntervalSince1970: 1),
        repositories: [RepositoryContext(path: folder)]
      )
    }
    let repository = WorkspaceRepository(sessions: sessions)
    let registry = WorkspaceRegistry(providers: [Self.provider])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    let plan = try await Self.provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: folder))
    for session in sessions {
      await launcher.launch(session: session, plan: plan)
    }
    // Loaded here, not by the window's own `.task`: finishing later, on a slow runner, that load
    // put back the session it found on screen over the one a ⌘-click had just shown.
    await model.load()

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    // Owned by this test, not by AppKit: a window made in code releases itself when closed.
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: RootView(model: model))
    return Workspace(model: model, sessions: sessions, window: window, folder: folder)
  }

  /// A state is waited for, not a deadline. The bound is far beyond what the slowest runner
  /// needs; it is only there so that a state never reached says which one, and how the window
  /// stood, rather than the suite's time limit saying nothing.
  private func waitUntil(
    _ what: String, in workspace: Workspace, _ condition: () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let start = clock.now
    while !condition() {
      guard clock.now - start < .seconds(45) else {
        throw NeverReached(description: "Never reached: \(what). \(workspace.state)")
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// What a click on a row, then ⌘-clicks on the two others, do: the list takes the keyboard,
  /// then reports each selection it draws.
  private func selectAll(in workspace: Workspace) async throws {
    let model = workspace.model
    let sessions = workspace.sessions
    model.select(sessions[0].id)
    try await waitUntil("the list, and the first session's terminal", in: workspace) {
      workspace.list != nil && workspace.shownTerminal(of: sessions[0]) != nil
    }
    let list = try #require(workspace.list)
    for count in 2...3 {
      workspace.window.makeFirstResponder(list)
      model.selectFromList(Set(workspace.ids.prefix(count)))
      // The session clicked is on screen once its terminal is: shown in the update that would
      // hand it the keyboard, if anything did.
      try await waitUntil("the terminal of \(sessions[count - 1].name)", in: workspace) {
        workspace.shownTerminal(of: sessions[count - 1]) != nil
      }
    }
  }

  /// Gives the keyboard to a view, and waits for the monitor to have looked where it went: it
  /// looks once the move is over.
  private func moveKeyboard(to view: NSView, in workspace: Workspace) async throws {
    let monitor = try #require(workspace.monitor)
    let seen = monitor.movesSeen
    workspace.window.makeFirstResponder(view)
    try await waitUntil("the monitor seeing the keyboard move", in: workspace) {
      monitor.movesSeen > seen
    }
  }

  @Test("⌘-clicking rows keeps the keyboard in the list, and the selection with it")
  func selectingKeepsTheKeyboard() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }

    try await selectAll(in: workspace)

    #expect(workspace.keyboardIsInTheList, "\(workspace.state)")
    #expect(Set(workspace.model.commandTargets) == Set(workspace.ids), "\(workspace.state)")
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
    try await waitUntil("a selection of one", in: workspace) { !model.hasMultipleSelection }

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
    try await waitUntil("a selection of one", in: workspace) { !model.hasMultipleSelection }

    #expect(model.commandTargets == [workspace.ids[2]])
  }

  @Test("Typing in a row's field keeps the selection: the field is in the list")
  func rowFieldKeepsTheSelection() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    try await selectAll(in: workspace)
    let list = try #require(workspace.list)

    // Stands for a group's name being edited in its header: a field drawn among the rows.
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    list.addSubview(field)
    defer { field.removeFromSuperview() }
    try await moveKeyboard(to: field, in: workspace)
    #expect(field.currentEditor() != nil)

    #expect(Set(workspace.model.commandTargets) == Set(workspace.ids), "\(workspace.state)")
  }

  @Test("Searching keeps the selection, pruned of the rows the search hides (#77)")
  func searchKeepsTheSelection() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    try await selectAll(in: workspace)
    let model = workspace.model
    let search = try #require(workspace.searchField, "\(workspace.state)")

    try await moveKeyboard(to: search, in: workspace)
    #expect(search.currentEditor() != nil)
    #expect(Set(model.commandTargets) == Set(workspace.ids), "\(workspace.state)")

    model.setSearchText("two")

    // In whatever order the search draws them.
    #expect(
      Set(model.commandTargets) == [workspace.ids[1], workspace.ids[2]], "\(workspace.state)")
    #expect(model.selectedSessionID == workspace.ids[2])
  }
}
