import AppKit
import Foundation
import SwiftUI
import Testing
import VibeApplication
import VibeBrowser
import VibeDomain
import VibeTerminalUI
import WebKit

@testable import VibeUI

/// What ⌘W closes in the real window (#165): the element inside the session that holds the
/// keyboard — a tab of the web view, its page or its address bar (ADR 0023), a side terminal
/// (#43) — and nothing when the keyboard is anywhere else: the session is ⇧⌘W's.
@MainActor
@Suite("⌘W follows the keyboard in the window", .serialized, .timeLimit(.minutes(2)))
struct CloseCommandRoutingTests {
  private static let provider = WorkspaceProvider()

  @MainActor private final class Workspace {
    let model: AppModel
    let session: WorkSession
    let drawer: SessionTerminalDrawer
    let window: NSWindow
    let folder: String

    init(
      model: AppModel, session: WorkSession, drawer: SessionTerminalDrawer, window: NSWindow,
      folder: String
    ) {
      self.model = model
      self.session = session
      self.drawer = drawer
      self.window = window
      self.folder = folder
    }

    /// The page on screen, once it has a size.
    var page: WKWebView? {
      all(BrowserWebViewContainer.self, in: window.contentView)
        .first { !$0.bounds.isEmpty }?
        .subviews.compactMap { $0 as? WKWebView }.first
    }

    /// The web view's address bar, on screen.
    var addressField: NSTextField? {
      all(NSTextField.self, in: window.contentView).first {
        $0.isEditable
          && ($0.placeholderString ?? $0.placeholderAttributedString?.string)
            == "Enter an address or #ticket"
      }
    }

    /// The agent's terminal, on screen.
    var agentTerminal: AccessibleTerminalView? {
      all(AccessibleTerminalView.self, in: window.contentView)
        .first { !$0.isHidden && $0.accessibilityTitle.contains("Terminal — \(session.name)") }
    }

    /// The side terminal in front of the drawer, on screen.
    var sideTerminal: AccessibleTerminalView? {
      all(AccessibleTerminalView.self, in: window.contentView)
        .first { !$0.isHidden && $0.accessibilityTitle.hasPrefix("Side terminal") }
    }

    var tabs: [BrowserTabModel] {
      model.browser?.browser(for: session.id).allTabs ?? []
    }

    var state: String {
      let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
      return """
        first responder: \(responder), page: \(page.map { "\($0.frame)" } ?? "none"), \
        target: \(String(describing: model.innerCloseTarget)), tabs: \(tabs.count), \
        session: \(String(describing: model.sessions.first?.status))
        """
    }

    func close() {
      window.contentView = nil
      window.close()
      try? FileManager.default.removeItem(atPath: folder)
    }

    func all<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
      guard let view else { return [] }
      if let match = view as? T { return [match] }
      return view.subviews.flatMap { all(type, in: $0) }
    }
  }

  private struct NeverReached: Error, CustomStringConvertible {
    let description: String
  }

  /// One running session, three pages open in its web view, shown beside its terminal — or in
  /// turns with it, in a window too narrow for both.
  private func workspace(width: CGFloat = 1600) async throws -> Workspace {
    _ = NSApplication.shared
    let folder = NSTemporaryDirectory().appending("vibe-close-routing-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let session = WorkSession(
      name: "Alpha", agent: SessionAgentConfiguration(providerID: "stub"), status: .closed,
      createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
      closedAt: Date(timeIntervalSince1970: 1), repositories: [RepositoryContext(path: folder)])
    let supervisor = WorkspaceSupervisor()
    let repository = WorkspaceRepository(sessions: [session])
    let registry = WorkspaceRegistry(providers: [Self.provider])
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry, viewportTimeout: .zero)
    let terminals = SessionTerminals(
      supervisor: supervisor, viewportTimeout: .milliseconds(1), sessionFolder: { _ in folder })
    let browser = BrowserWorkspace()
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher,
      layout: WorkspaceLayoutController(store: RecordingLayoutStore()), browser: browser,
      terminals: terminals)
    let plan = try await Self.provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: folder))
    await launcher.launch(session: session, plan: plan)
    await model.load()
    model.select(session.id)
    for page in ["first", "second", "third"] {
      _ = browser.open(
        URL(string: "data:text/html,<p>\(page)</p><input>")!, in: session.id, openedBy: .user)
    }
    let tabs = browser.browser(for: session.id)
    if let first = tabs.allTabs.first { tabs.activate(first.id) }
    browser.setVisible(true, for: session.id)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: RootView(model: model))
    let workspace = Workspace(
      model: model, session: session, drawer: terminals.drawer(for: session.id), window: window,
      folder: folder)
    if width < WorkspaceLayoutPolicy.browserBesideThreshold {
      try await waitUntil("the web view taking turns with the terminal", in: workspace) {
        model.layout.columns.browser == .alternating
      }
      model.layout.setShowsBrowserWhenAlternating(true)
    }
    try await waitUntil("the page and the terminal on screen", in: workspace) {
      workspace.page != nil && workspace.agentTerminal != nil && workspace.tabs.count == 3
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

  private func commandW() -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
      isARepeat: false, keyCode: 13)!
  }

  private func commandT() -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: 0, context: nil, characters: "t", charactersIgnoringModifiers: "t",
      isARepeat: false, keyCode: 17)!
  }

  @Test(
    "With the keyboard in the page or its address bar, ⌘W closes the tab, then the next one",
    arguments: [1600, 800] as [CGFloat], [false, true])
  func closesTabAfterTab(width: CGFloat, inAddressBar: Bool) async throws {
    let workspace = try await workspace(width: width)
    defer { workspace.close() }
    let model = workspace.model
    let page = try #require(workspace.page)

    if inAddressBar {
      model.focusAddressBar()
    } else {
      #expect(workspace.window.makeFirstResponder(page), "\(workspace.state)")
    }
    try await waitUntil("⌘W aimed at the web tab", in: workspace) {
      model.innerCloseTarget == .webTab
    }

    // What the key does in the window: the tab in front goes, and its neighbour comes forward.
    #expect(workspace.window.performKeyEquivalent(with: commandW()), "\(workspace.state)")
    try await waitUntil("the next page on screen", in: workspace) {
      workspace.tabs.count == 2 && workspace.page.map { $0 !== page } == true
    }

    // The keyboard stays where it was: the next ⌘W closes the next tab, not the session.
    try await waitUntil("⌘W aimed at the next tab", in: workspace) {
      model.innerCloseTarget == .webTab
        && (inAddressBar || workspace.window.firstResponder === workspace.page)
    }
    #expect(workspace.window.performKeyEquivalent(with: commandW()), "\(workspace.state)")
    try await waitUntil("a second tab closed", in: workspace) { workspace.tabs.count == 1 }
    #expect(model.pendingClose == nil, "\(workspace.state)")
    #expect(model.sessions.first?.status == .active, "\(workspace.state)")
  }

  @Test("New Tab opens an empty tab beside the page in front; ⌘L still sends that page away")
  func newTabOpensBeside() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    let model = workspace.model
    let front = try #require(model.activeWebTab)
    let address = front.url

    // The “+” of the tab bar, the Web menu's New Tab and ⌘T in the web view (#247): a tab shows at
    // once, empty, its address bar holding the keyboard.
    model.newWebTab()
    try await waitUntil("an empty tab, its field holding the keyboard", in: workspace) {
      workspace.tabs.count == 4 && model.isAddressBarFocused
        && workspace.addressField?.stringValue == ""
    }
    let blank = try #require(model.activeWebTab)
    #expect(blank.isBlank, "\(workspace.state)")

    // Return on the empty field opens nothing more.
    model.navigateWebTab(to: "")
    #expect(workspace.tabs.count == 4, "\(workspace.state)")

    // What is typed goes to the new tab; the page that was in front stays where it was.
    model.navigateWebTab(to: "about:blank#typed")
    try await waitUntil("the new tab sent to what was typed", in: workspace) {
      blank.url.absoluteString == "about:blank#typed"
    }
    #expect(workspace.tabs.count == 4, "\(workspace.state)")
    #expect(front.url == address, "\(workspace.state)")

    // Open Location, ⌘L, is unchanged: what is typed replaces the page in front, in place.
    model.focusAddressBar()
    try await waitUntil("the address bar holding the keyboard", in: workspace) {
      model.isAddressBarFocused
    }
    model.navigateWebTab(to: "about:blank#located")
    try await waitUntil("the page in front sent away", in: workspace) {
      model.activeWebTab?.url.absoluteString == "about:blank#located"
    }
    #expect(workspace.tabs.count == 4, "\(workspace.state)")
  }

  @Test("⌘T in the page opens an empty tab whose address bar, not its page, takes the keyboard")
  func commandTInPageOpensEmptyTab() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    let model = workspace.model
    let page = try #require(workspace.page)
    #expect(workspace.window.makeFirstResponder(page), "\(workspace.state)")
    try await waitUntil("the page holding the keyboard", in: workspace) { model.isWebPageFocused }

    #expect(workspace.window.performKeyEquivalent(with: commandT()), "\(workspace.state)")
    try await waitUntil("an empty tab, its field holding the keyboard", in: workspace) {
      workspace.tabs.count == 4 && model.activeWebTab?.isBlank == true
        && model.isAddressBarFocused && workspace.addressField?.stringValue == ""
    }
    // Still there once the new page is on screen and no longer owed the keyboard the old one had:
    // it did not take it back.
    try await waitUntil("the new page on screen, owed nothing", in: workspace) {
      workspace.page.map { $0 !== page } == true
        && model.browser?.pageLeftWithKeyboard == false
    }
    #expect(model.isAddressBarFocused, "\(workspace.state)")
  }

  @Test("Another tab brought forward takes the keyboard the page had")
  func switchingTabsKeepsTheKeyboard() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    let model = workspace.model
    let page = try #require(workspace.page)
    workspace.window.makeFirstResponder(page)
    try await waitUntil("⌘W aimed at the web tab", in: workspace) {
      model.innerCloseTarget == .webTab
    }

    model.selectNextWebTab()
    try await waitUntil("the next page on screen, with the keyboard", in: workspace) {
      guard let shown = workspace.page, shown !== page else { return false }
      return workspace.window.firstResponder === shown && model.innerCloseTarget == .webTab
    }
  }

  @Test("A tab brought forward while the keyboard is elsewhere leaves it there")
  func switchingTabsElsewhereLeavesTheKeyboard() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    let model = workspace.model
    let page = try #require(workspace.page)
    let terminal = try #require(workspace.agentTerminal)
    workspace.window.makeFirstResponder(terminal)
    try await waitUntil("the agent's terminal holding the keyboard", in: workspace) {
      workspace.window.firstResponder === terminal && model.innerCloseTarget == nil
    }

    // ⌃⇥, then an agent's tab_activate, which activates the tab the same way.
    model.selectNextWebTab()
    try await waitUntil("the second page on screen", in: workspace) {
      workspace.page.map { $0 !== page } == true
    }
    let second = try #require(workspace.page)
    let browser = try #require(model.selectedBrowser)
    let third = try #require(browser.allTabs.last)
    browser.activate(third.id)
    try await waitUntil("the third page on screen", in: workspace) {
      workspace.page.map { $0 !== page && $0 !== second } == true
    }
    #expect(workspace.window.firstResponder === terminal, "\(workspace.state)")
    #expect(model.innerCloseTarget == nil, "\(workspace.state)")
  }

  @Test("The web view moved from beside the terminal to taking turns with it keeps the keyboard")
  func layoutChangeKeepsTheKeyboard() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    let model = workspace.model
    let page = try #require(workspace.page)
    workspace.window.makeFirstResponder(page)
    try await waitUntil("⌘W aimed at the web tab", in: workspace) {
      model.innerCloseTarget == .webTab
    }

    // Too narrow for both: the web view takes turns with the terminal, in another view.
    model.layout.setShowsBrowserWhenAlternating(true)
    var frame = workspace.window.frame
    frame.size.width = 800
    workspace.window.setFrame(frame, display: false)
    try await waitUntil("the page taking turns with the terminal, with the keyboard", in: workspace)
    {
      model.layout.columns.browser == .alternating && workspace.page === page
        && workspace.window.firstResponder === page && model.innerCloseTarget == .webTab
    }

    // And back beside it.
    frame.size.width = 1600
    workspace.window.setFrame(frame, display: false)
    try await waitUntil("the page beside the terminal, with the keyboard", in: workspace) {
      model.layout.columns.browser == .beside && workspace.page === page
        && workspace.window.firstResponder === page && model.innerCloseTarget == .webTab
    }
  }

  @Test("With the keyboard in the agent's terminal, ⌘W closes nothing; in the drawer, its tab")
  func terminalAndDrawer() async throws {
    let workspace = try await workspace()
    defer { workspace.close() }
    let model = workspace.model

    // The agent's terminal: nothing inside the session holds the keyboard, and the session is
    // ⇧⌘W's — ⌘W leaves it alone.
    let terminal = try #require(workspace.agentTerminal)
    workspace.window.makeFirstResponder(terminal)
    try await waitUntil("⌘W aimed at nothing", in: workspace) {
      model.innerCloseTarget == nil
    }
    model.closeInnerElement()
    #expect(model.pendingClose == nil, "\(workspace.state)")
    #expect(model.sessions.first?.status == .active, "\(workspace.state)")
    #expect(workspace.tabs.count == 3, "\(workspace.state)")

    // The drawer: ⌘W closes its terminal in front, or asks first while a command runs in it.
    await workspace.drawer.show()
    try await waitUntil("a side terminal on screen", in: workspace) {
      workspace.sideTerminal != nil
    }
    let side = try #require(workspace.sideTerminal)
    workspace.window.makeFirstResponder(side)
    try await waitUntil("⌘W aimed at the side terminal", in: workspace) {
      model.innerCloseTarget == .drawerTerminal
    }
    model.closeInnerElement()
    try await waitUntil("the side terminal closed, or its close asked about", in: workspace) {
      workspace.drawer.terminals.isEmpty || model.pendingTerminalClose != nil
    }
    #expect(model.pendingClose == nil, "\(workspace.state)")
    #expect(model.sessions.first?.status == .active, "\(workspace.state)")
  }
}
