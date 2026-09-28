import AppKit
import Foundation
import SwiftUI
import Testing
import VibeApplication
import VibeBrowser
import VibeDomain
import VibeTerminalUI

@testable import VibeUI

/// What showing the web view, or folding the sidebar, costs the terminals behind it (#149, #150):
/// counted in work done — terminals remade, histories replayed, scrollbacks reflowed — rather than
/// in seconds, which a slow runner would make lie.
@MainActor
@Suite(
  "Showing the web view and folding the sidebar spare the terminals", .serialized,
  .timeLimit(.minutes(2)))
struct WebViewToggleTests {
  private static let provider = WorkspaceProvider()

  /// Three running sessions with some history each, their terminals mounted by the real window.
  @MainActor private final class Workspace {
    let model: AppModel
    let sessions: [WorkSession]
    let supervisor: WorkspaceSupervisor
    let window: NSWindow
    let folder: String

    init(
      model: AppModel, sessions: [WorkSession], supervisor: WorkspaceSupervisor,
      window: NSWindow, folder: String
    ) {
      self.model = model
      self.sessions = sessions
      self.supervisor = supervisor
      self.window = window
      self.folder = folder
    }

    var terminals: [AccessibleTerminalView] {
      Self.all(AccessibleTerminalView.self, in: window.contentView)
    }

    func shownTerminal(of session: WorkSession) -> AccessibleTerminalView? {
      terminals.first { !$0.isHidden && $0.accessibilityTitle.contains(session.name) }
    }

    /// The view the page is shown in, once it is on screen with a size.
    var page: BrowserWebViewContainer? {
      Self.all(BrowserWebViewContainer.self, in: window.contentView)
        .first { !$0.bounds.isEmpty }
    }

    /// How many times a view attached to each terminal, replaying its history.
    func attachCount() async -> Int {
      var total = 0
      for session in sessions {
        if let terminal = await supervisor.session(for: session.id.agentTerminal)
          as? WorkspaceTerminal
        {
          total += await terminal.attachCount
        }
      }
      return total
    }

    var state: String {
      let shown = terminals.map {
        "\($0.isHidden ? "hidden" : "shown") \($0.accessibilityTitle) \($0.frame.size)"
      }
      return """
        terminals: \(shown), page: \(page.map { "\($0.bounds.size)" } ?? "none"), \
        web view open: \(model.isWebViewOpen), columns: \(model.layout.columns.browser)
        """
    }

    func close() {
      window.contentView = nil
      window.close()
      try? FileManager.default.removeItem(atPath: folder)
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
    _ = NSApplication.shared
    let folder = NSTemporaryDirectory().appending("vibe-web-toggle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let sessions = ["Alpha", "Bravo", "Charlie"].enumerated().map { index, name in
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
    var history: [UInt8] = []
    for line in 0..<2_000 {
      history += Array("\u{1B}[32mline \(line)\u{1B}[0m of what the agent printed\r\n".utf8)
    }
    let supervisor = WorkspaceSupervisor(history: history)
    let repository = WorkspaceRepository(sessions: sessions)
    let registry = WorkspaceRegistry(providers: [Self.provider])
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry, viewportTimeout: .zero)
    let browser = BrowserWorkspace()
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher,
      layout: WorkspaceLayoutController(store: RecordingLayoutStore()), browser: browser)
    let plan = try await Self.provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: folder))
    for session in sessions {
      await launcher.launch(session: session, plan: plan)
    }
    await model.load()
    model.select(sessions[0].id)
    // A page already open, the web view hidden: the button only shows it.
    _ = browser.open(URL(string: "about:blank")!, in: sessions[0].id, openedBy: .user)
    browser.setVisible(false, for: sessions[0].id)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1800, height: 1000),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: RootView(model: model))
    let workspace = Workspace(
      model: model, sessions: sessions, supervisor: supervisor, window: window, folder: folder)
    // The one on screen laid out at the window's size — the first layout passes go through sizes
    // of their own — and the hidden ones given a first size.
    try await waitUntil("every terminal sized, the first one on screen at full size", in: workspace)
    {
      let terminals = workspace.terminals
      guard terminals.count == sessions.count, let shown = workspace.shownTerminal(of: sessions[0])
      else { return false }
      return shown.frame.width > 1000 && shown.frame.height > 500
        && terminals.allSatisfy { !$0.frame.isEmpty }
    }
    return workspace
  }

  /// A state is waited for, not a deadline: the bound only makes a state never reached say which.
  private func waitUntil(
    _ what: String, in workspace: Workspace, _ condition: () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let start = clock.now
    while true {
      workspace.window.contentView?.layoutSubtreeIfNeeded()
      if condition() { return }
      guard clock.now - start < .seconds(45) else {
        throw NeverReached(description: "Never reached: \(what). \(workspace.state)")
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test("Showing and hiding the web view remakes no terminal and replays no history (#149)")
  func toggleKeepsTheTerminals() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    let model = workspace.model
    let terminals = workspace.terminals.map(ObjectIdentifier.init)
    let attached = await workspace.attachCount()

    model.toggleWebView()
    try await waitUntil("the web view beside the terminal", in: workspace) {
      model.isWebViewOpen && workspace.page != nil
        && workspace.terminals.count == workspace.sessions.count
    }
    #expect(workspace.terminals.map(ObjectIdentifier.init) == terminals, "\(workspace.state)")
    #expect(await workspace.attachCount() == attached)

    model.toggleWebView()
    try await waitUntil("the web view gone", in: workspace) {
      !model.isWebViewOpen && workspace.page == nil
        && workspace.terminals.count == workspace.sessions.count
    }
    #expect(workspace.terminals.map(ObjectIdentifier.init) == terminals, "\(workspace.state)")
    #expect(await workspace.attachCount() == attached)
  }
}
