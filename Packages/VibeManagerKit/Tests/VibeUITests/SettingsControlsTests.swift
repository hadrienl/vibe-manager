import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeBrowser
import VibeConversationUI
import VibeDomain

@testable import VibeUI

/// Each switch and each segmented control of the settings pages (#313) reaches what it sets:
/// clicked as the user clicks it, in a window that is never shown. SwiftUI draws the menus and
/// the buttons of a form itself; the switches and the segmented controls are AppKit's.
@Suite("The controls of the settings", .timeLimit(.minutes(2)))
@MainActor
struct SettingsControlsTests {
  @Test("General: where sessions open, and the question before closing one")
  func general() async throws {
    let model = Self.workspace()
    let page = SettingsPageWindow(model: model, page: .general)
    defer { page.close() }
    await page.settle("the page") { !page.segmented().isEmpty && !page.switches().isEmpty }

    let opening = try #require(page.segmented().first)
    #expect(model.conversations.appearance.defaultPresentation == .conversation)
    page.choose(1, in: opening)
    await page.settle("sessions open in the terminal") {
      model.conversations.appearance.defaultPresentation == .terminal
    }

    let asks = model.confirmsStoppingRunningAgent
    page.click(page.switches()[0])
    await page.settle("the question changed") { model.confirmsStoppingRunningAgent != asks }
  }

  @Test("Notifications: the floating panel, the notifications, the Dock and the palette")
  func notifications() async throws {
    let model = Self.workspace()
    let panel = FloatingRequestPanelModel(preferences: InMemoryFloatingPanelPreferences())
    panel.isEnabled = false
    model.floatingPanel = panel
    let page = SettingsPageWindow(model: model, page: .requests)
    defer { page.close() }
    await page.settle("the four switches") { page.switches().count == 4 }

    let settings: [(String, () -> Bool)] = [
      ("the floating panel", { panel.isEnabled }),
      ("the notifications", { model.notifiesRequests }),
      ("the Dock's badge", { model.showsRequestDockBadge }),
      ("the palette", { model.expandsPaletteOnRequest }),
    ]
    // From the bottom: the floating panel turned on greys the notifications out.
    for (index, (name, value)) in settings.enumerated().reversed() {
      let before = value()
      page.click(page.switches()[index])
      await page.settle("\(name) changed") { value() != before }
    }
  }

  @Test("Conversation: light and dark, and each technical detail")
  func conversation() async throws {
    let model = Self.workspace()
    let page = SettingsPageWindow(model: model, page: .conversation)
    defer { page.close() }
    await page.settle("the switches") { page.switches().count >= 7 }

    let appearance = { model.conversations.appearance }
    let settings: [(String, () -> Bool)] = [
      ("light and dark", { appearance().followsSystemAppearance }),
      ("grouped calls", { appearance().groupsToolCalls }),
      ("failures", { appearance().expandsFailures }),
      ("edits", { appearance().expandsEdits }),
      ("reasoning", { appearance().showsReasoning }),
      ("wrapped code", { appearance().wrapsCode }),
      ("line numbers", { appearance().showsDiffLineNumbers }),
    ]
    for (index, (name, value)) in settings.enumerated() {
      let before = value()
      page.click(page.switches()[index])
      await page.settle("\(name) changed") { value() != before }
    }
  }

  @Test("Web View: the web view given to agents, and shown when they open a page")
  func webView() async throws {
    let model = Self.workspace()
    let preferences = try #require(model.browser?.preferences)
    let page = SettingsPageWindow(model: model, page: .webView)
    defer { page.close() }
    await page.settle("the switches") { page.switches().count == 2 }

    let gives = preferences.givesAgentsWebView
    page.click(page.switches()[0])
    await page.settle("given to agents changed") { preferences.givesAgentsWebView != gives }
    let shows = preferences.showsWebViewWhenAgentOpensPage
    page.click(page.switches()[1])
    await page.settle("shown changed") { preferences.showsWebViewWhenAgentOpensPage != shows }
  }

  @Test("Tickets: the titles inserted in the notes")
  func tickets() async throws {
    let model = Self.workspace()
    let page = SettingsPageWindow(model: model, page: .tickets)
    defer { page.close() }
    await page.settle("the switch, once the resolvers are read") {
      model.ticketTitles.isLoaded && page.switches().first?.isEnabled == true
    }
    let inserts = model.ticketTitles.insertsTicketTitles
    page.click(page.switches()[0])
    await page.settle("the setting changed") { model.ticketTitles.insertsTicketTitles != inserts }
  }

  @Test("An agent: whether its activity is tracked")
  func agent() async throws {
    let model = Self.workspace()
    let codex = AgentDescriptor(id: AgentProviderID("codex"), displayName: "Codex")
    model.agentDescriptors = [codex]
    model.hookTrustingAgents = [codex]
    model.reportsActivity = [codex.id: true]
    let page = SettingsPageWindow(model: model, page: .agent(codex.id))
    defer { page.close() }
    await page.settle("the switch") { page.switches().count == 1 }

    page.click(page.switches()[0])
    await page.settle("its activity no longer tracked") { model.reportsActivity[codex.id] == false }
    page.click(page.switches()[0])
    await page.settle("tracked again") { model.reportsActivity[codex.id] == true }
  }

  @Test("An agent that tracks nothing has a page, without the switch; the mock agent has none")
  func agentWithoutActivity() async {
    let model = Self.workspace()
    let claude = AgentDescriptor(id: AgentProviderID("claude"), displayName: "Claude Code")
    model.agentDescriptors = [
      claude, AgentDescriptor(id: AgentProviderID("mock"), displayName: "Mock"),
    ]
    let sidebar = SettingsSidebarContent(model: model, permissions: nil)
    #expect(sidebar.groups.first { $0.id == "agents" }?.entries.map(\.name) == ["Claude Code"])
    let page = SettingsPageWindow(model: model, page: .agent(claude.id))
    defer { page.close() }
    await page.settle("the page") { page.window.title == "Claude Code" }
    #expect(page.switches().isEmpty)
  }

  static func workspace() -> AppModel {
    _ = NSApplication.shared
    return AppModel(
      repository: StubRepository(sessions: []),
      layout: WorkspaceLayoutController(store: RecordingLayoutStore()), browser: BrowserWorkspace())
  }
}

/// A page of the settings in a window of its own, never put on screen.
@MainActor
struct SettingsPageWindow {
  let window: NSWindow
  let host: NSHostingController<AnyView>

  init(model: AppModel, page: SettingsPage) {
    model.settingsPage = page
    host = NSHostingController(
      rootView: AnyView(
        SettingsView(model: model).environment(\.locale, Locale(identifier: "en"))))
    // Tall enough for every control of the page to be laid out, none scrolled away.
    let size = NSSize(width: SettingsSplitView.sidebarWidth + page.detailWidth, height: 1_400)
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = host
    window.setContentSize(size)
  }

  func close() { window.close() }

  /// Lays the window out until `condition` holds.
  func settle(
    _ what: String, sourceLocation: SourceLocation = #_sourceLocation,
    until condition: @MainActor () -> Bool
  ) async {
    await waitUntil(what, sourceLocation: sourceLocation) {
      window.contentView?.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return condition()
    }
  }

  /// The page's switches, from the top.
  func switches() -> [NSControl] {
    controls().filter { String(describing: type(of: $0)).contains("Switch") }
  }

  /// The page's segmented controls, from the top.
  func segmented() -> [NSSegmentedControl] {
    controls().compactMap { $0 as? NSSegmentedControl }
  }

  /// Clicks `control`, as the mouse does.
  func click(_ control: NSControl) {
    control.performClick(nil)
  }

  /// Chooses the segment `index` of `control`, as a click on it does.
  func choose(_ index: Int, in control: NSSegmentedControl) {
    control.selectedSegment = index
    _ = control.sendAction(control.action, to: control.target)
  }

  private func controls() -> [NSControl] {
    func descendants(_ view: NSView) -> [NSView] {
      view.subviews.flatMap { [$0] + descendants($0) }
    }
    return descendants(host.view)
      .compactMap { $0 as? NSControl }
      .filter { !$0.isHiddenOrHasHiddenAncestor }
      .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
  }
}
