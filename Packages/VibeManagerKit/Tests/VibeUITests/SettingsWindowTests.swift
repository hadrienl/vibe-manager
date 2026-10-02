import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeBrowser
import VibeConversationUI
import VibeDomain
import VibeLocalizationTesting

@testable import VibeUI

/// The settings window (#313): a sidebar of pages, a window that keeps its width from one page to
/// the next, and widens for a page that needs more.
@Suite("The settings window", .timeLimit(.minutes(2)))
@MainActor
struct SettingsWindowTests {
  private static let screen = NSRect(x: 0, y: 0, width: 1_600, height: 1_000)

  @Test("A page wider than the window widens it, and the width is given back after")
  func widensThenComesBack() throws {
    let frame = NSRect(x: 100, y: 200, width: 835, height: 700)
    let wide = try #require(
      SettingsWindowWidth.plan(frame: frame, needed: 1_225, restoredWidth: nil, screen: Self.screen))
    #expect(wide.frame == NSRect(x: 100, y: 200, width: 1_225, height: 700))
    #expect(wide.restoredWidth == 835)

    // Between the two: as wide as that page needs, the width to give back kept.
    let middle = try #require(
      SettingsWindowWidth.plan(
        frame: wide.frame, needed: 1_115, restoredWidth: wide.restoredWidth, screen: Self.screen))
    #expect(middle.frame.width == 1_115)
    #expect(middle.restoredWidth == 835)

    let back = try #require(
      SettingsWindowWidth.plan(
        frame: middle.frame, needed: 835, restoredWidth: middle.restoredWidth, screen: Self.screen))
    #expect(back.frame == frame)
    #expect(back.restoredWidth == nil)
  }

  @Test("A window the user made wide enough is left as it is")
  func wideEnoughIsLeft() {
    let frame = NSRect(x: 100, y: 200, width: 1_300, height: 700)
    #expect(
      SettingsWindowWidth.plan(frame: frame, needed: 1_225, restoredWidth: nil, screen: Self.screen)
        == nil)
    #expect(
      SettingsWindowWidth.plan(frame: frame, needed: 835, restoredWidth: nil, screen: Self.screen)
        == nil)
  }

  @Test("Widened near the edge, the window moves left, and never past the screen")
  func staysOnScreen() throws {
    let frame = NSRect(x: 1_000, y: 200, width: 835, height: 700)
    let plan = try #require(
      SettingsWindowWidth.plan(frame: frame, needed: 1_225, restoredWidth: nil, screen: Self.screen))
    #expect(plan.frame.maxX == Self.screen.maxX)
    #expect(plan.frame.width == 1_225)

    let small = NSRect(x: 0, y: 0, width: 1_100, height: 800)
    let clamped = try #require(
      SettingsWindowWidth.plan(
        frame: NSRect(x: 50, y: 0, width: 835, height: 700), needed: 1_225, restoredWidth: nil,
        screen: small))
    #expect(clamped.frame.width == small.width)
    #expect(clamped.frame.minX == small.minX)
  }

  @Test("The sidebar lists the pages of the workspace, in their groups")
  func sidebarGroups() async {
    let model = Self.workspace()
    let endpoints = Self.endpoints()
    await endpoints.load()
    model.endpoints = endpoints
    let sidebar = SettingsSidebarContent(model: model, permissions: nil)
    #expect(sidebar.groups.map(\.id) == ["application", "endpoints", "tools"])
    #expect(
      sidebar.groups.first?.entries.map(\.page) == [
        .general, .conversation, .sessionAppearance, .requests,
      ])
    let rows = sidebar.groups[1].entries
    #expect(rows.map(\.name).first == "OpenRouter")
    #expect(rows.last?.page == .newEndpoint)
    #expect(sidebar.groups[2].entries.map(\.page).prefix(2) == [.webView, .templates])
  }

  @Test("A page the workspace does not have shows General, and a page reached from another keeps its name")
  func shownPage() {
    let model = Self.workspace()
    let sidebar = SettingsSidebarContent(model: model, permissions: nil)
    #expect(sidebar.shown(.endpoint(EndpointID())) == .general)
    #expect(sidebar.shown(.agent(AgentProviderID("gone"))) == .general)
    #expect(sidebar.shown(.templates) == .templates)
    #expect(sidebar.name(of: .templates) == String(localized: SettingsPage.templates.title))
    let french = SettingsSidebarContent(model: model, permissions: nil, locale: Locale(identifier: "fr"))
    #expect(french.name(of: .templates) == "Gabarits")
    #expect(french.groups.first?.entries.first?.name == "Général")
  }

  /// What each page needs at least fits the width the window gives it: below it, the window
  /// would cut it, as the toolbar of tabs did (#129, #152).
  @Test(
    "Each page fits in the width the window gives it",
    arguments: [
      SettingsPage.general, .conversation, .sessionAppearance, .requests, .webView, .templates,
      .tickets, .ticketResolvers, .privacy, .newEndpoint,
    ], ["en", "fr"])
  func pageFits(page: SettingsPage, language: String) async {
    let model = Self.workspace()
    model.endpoints = Self.endpoints()
    if page == .templates {
      // The list the user has, and one of them open, as in the report of #152.
      await model.templates.load()
      await model.templates.addExamples()
      model.templates.requestSelect(model.templates.library.templates.first?.id)
    }
    let host = NSHostingController(
      rootView: SettingsPageView(model: model, permissions: nil, page: page)
        .environment(\.locale, Locale(identifier: language)))
    let least = host.sizeThatFits(in: .zero).width
    #expect(least <= page.detailWidth + 0.5, "\(page) needs \(least) points")
  }

  @Test("An endpoint has a page of its own, which fits the window")
  func endpointPage() async throws {
    let model = Self.workspace()
    let endpoints = Self.endpoints()
    model.endpoints = endpoints
    await endpoints.load()
    let endpoint = try #require(endpoints.endpoints.first)
    let page = SettingsPage.endpoint(endpoint.id)
    #expect(SettingsSidebarContent(model: model, permissions: nil).shown(page) == page)
    #expect(SettingsSidebarContent(model: model, permissions: nil).name(of: page) == "OpenRouter")
    let host = NSHostingController(
      rootView: SettingsPageView(model: model, permissions: nil, page: page))
    #expect(host.sizeThatFits(in: .zero).width <= page.detailWidth + 0.5)
  }

  @Test("The settings window is at least as wide as a page that is a form")
  func leastWindow() {
    let host = NSHostingController(rootView: SettingsView(model: Self.workspace()))
    let least = host.sizeThatFits(in: .zero)
    #expect(least.width >= SettingsSplitView.standardWidth - 0.5)
    #expect(least.height >= SettingsSplitView.minimumHeight - 0.5)
  }

  @Test("Other Server is the only start that asks for a protocol")
  func presets() {
    let presets = EndpointsSettingsModel.presets
    #expect(presets.map(\.id) == ["ollama", "lmstudio", "openrouter", "other"])
    #expect(presets.last?.id == EndpointsSettingsModel.otherPresetID)
  }

  private static func workspace() -> AppModel {
    _ = NSApplication.shared
    return AppModel(
      repository: StubRepository(sessions: []),
      layout: WorkspaceLayoutController(store: RecordingLayoutStore()), browser: BrowserWorkspace())
  }

  /// The endpoints of a user who declared one.
  static func endpoints() -> EndpointsSettingsModel {
    EndpointsSettingsModel(
      repository: InMemoryEndpointRepository(endpoints: [
        Endpoint(
          name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
          wireProtocol: .chatCompletions,
          models: [
            EndpointModel(id: "qwen/qwen3-coder", contextWindow: 262_144),
            EndpointModel(id: "moonshotai/kimi-k2", contextWindow: 131_072),
            EndpointModel(id: "tiny", contextWindow: 8_192, supportsTools: false),
          ],
          lastTest: EndpointTestOutcome(verdict: .passedWithWarnings, date: Date()))
      ]),
      secrets: InMemoryEndpointSecretStore(),
      probing: NoProbing())
  }
}

private struct NoProbing: EndpointProbing {
  func discoverModels(for endpoint: Endpoint, secret: String?) async throws -> [EndpointModel] {
    []
  }

  func test(_ endpoint: Endpoint, secret: String?, model: String) async -> EndpointTestReport {
    EndpointTestReport(model: model, date: Date(), checks: [])
  }
}
