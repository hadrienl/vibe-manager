import AppKit
import SwiftUI
import Testing
import VibeBrowser
import VibeConversationUI
import VibeLocalizationTesting

@testable import VibeUI

/// The settings window takes the size of the tab shown, and its toolbar holds every tab: a tab
/// narrower than the toolbar needs sends the last ones into an overflow menu where SwiftUI greys
/// them out (#129).
@Suite("The width of the settings window", .timeLimit(.minutes(1)))
@MainActor
struct SettingsWidthTests {
  @Test("Every tab fits in the toolbar at the settings' width", arguments: ["en", "fr"])
  func toolbarHoldsEveryTab(language: String) {
    let window = Self.toolbarWindow(language: language)
    defer { window.close() }

    #expect(Self.visibleTabs(in: window, width: SettingsView.formWidth) == 9)
    // The measure can see an overflow: at the width of #129, the last tabs are out.
    #expect(Self.visibleTabs(in: window, width: 500) < 9)
  }

  @Test("A tab narrower than the toolbar needs is widened")
  func narrowPageIsWidened() {
    let page = NSHostingView(
      rootView: Color.clear.frame(width: 300, height: 100).settingsPage(.general))
    #expect(page.fittingSize.width >= SettingsView.formWidth)
  }

  /// The tabs a workspace assembled with a web view offers. The others need the system around
  /// them, and take their width from `settingsPage` the same way.
  @Test(
    "Each tab shown is at least as wide as the settings' width",
    arguments: [SettingsTab.general, .templates, .webView, .conversation, .requests])
  func everyTabIsWideEnough(tab: SettingsTab) {
    _ = NSApplication.shared
    let model = AppModel(
      repository: StubRepository(sessions: []),
      layout: WorkspaceLayoutController(store: RecordingLayoutStore()), browser: BrowserWorkspace())
    model.settingsTab = tab
    let host = NSHostingView(rootView: SettingsView(model: model))
    #expect(host.fittingSize.width >= SettingsView.formWidth)
  }

  @Test(
    "A page wider than the settings gives the window its least width",
    arguments: [(921.0, 921.0), (1008.0, 1180.0)])
  func widePageGivesItsWidth(least: Double, ideal: Double) {
    _ = NSApplication.shared
    let content = Color.clear.frame(
      minWidth: least, idealWidth: ideal, maxWidth: .infinity, minHeight: 100)
    let page = NSHostingController(rootView: content.settingsPage(.templates))
    #expect(abs(page.sizeThatFits(in: .zero).width - least) < 0.5)
  }

  /// The tabs wider than the settings' form (#152): shown in a window no larger than the least
  /// size the settings accept, each is whole. The settings window reads that least size: with a
  /// `frame(minWidth:)` it stayed at 780 points, and these pages overflowed it on both sides.
  @Test(
    "A wide tab is whole in the least window the settings accept",
    arguments: [SettingsTab.templates, .tickets, .conversation], ["en", "fr"])
  func wideTabIsWhole(tab: SettingsTab, language: String) async throws {
    _ = NSApplication.shared
    let model = AppModel(
      repository: StubRepository(sessions: []),
      layout: WorkspaceLayoutController(store: RecordingLayoutStore()), browser: BrowserWorkspace())
    model.settingsTab = tab
    if tab == .templates {
      // The list the user has, and one of them open, as in the report of #152.
      await model.templates.load()
      await model.templates.addExamples()
      model.templates.requestSelect(model.templates.library.templates.first?.id)
    }
    let locale = Locale(identifier: language)
    let host = NSHostingController(
      rootView: SettingsView(model: model).environment(\.locale, locale))
    let least = host.sizeThatFits(in: .zero)
    // What the page alone needs at least, without the settings around it.
    let page: AnyView =
      switch tab {
      case .templates: AnyView(PromptTemplatesView(model: model.templates))
      case .tickets: AnyView(TicketSettingsView(model: model.ticketTitles))
      default:
        AnyView(ConversationSettingsView(appearance: Bindable(model.conversations).appearance))
      }
    let alone = NSHostingController(rootView: page.environment(\.locale, locale))
    #expect(least.width >= alone.sizeThatFits(in: .zero).width)

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: least), styleMask: [.titled], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentViewController = host
    window.setContentSize(least)
    defer { window.close() }
    // The page is looked at once what it shows is there: the resolver the tab selects, the list
    // of templates, the form of the conversation.
    let view = host.view
    for _ in 0..<5_000 where !Self.hasLoaded(tab, model: model, in: view) {
      view.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      await Task.yield()
    }
    #expect(Self.hasLoaded(tab, model: model, in: view))

    // Measured in the tab view, which holds the page: SwiftUI places the views above it itself.
    let tabView = try #require(
      Self.descendants(of: view).lazy.compactMap { $0 as? NSTabView }.first)
    let cut = Self.drawnViews(in: tabView).filter { frame in
      frame.minX < tabView.bounds.minX - 0.5 || frame.maxX > tabView.bounds.maxX + 0.5
    }
    #expect(cut.isEmpty, "Views outside the tab of \(tabView.bounds.width) points: \(cut)")

    if let folder = ProcessInfo.processInfo.environment["VIBE_SETTINGS_SNAPSHOTS"] {
      let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: image)
      let data = try #require(image.representation(using: .png, properties: [:]))
      try data.write(
        to: URL(fileURLWithPath: folder).appendingPathComponent(
          "settings-\(tab.rawValue)-\(language).png"))
    }
  }

  private static func hasLoaded(_ tab: SettingsTab, model: AppModel, in view: NSView) -> Bool {
    let views = descendants(of: view)
    switch tab {
    case .tickets:
      return model.ticketTitles.isLoaded
        && views.contains { ($0 as? NSTextField)?.stringValue.contains("github") == true }
    case .templates:
      return model.templates.editing != nil && views.contains { $0 is NSTableView }
    default:
      return views.contains { $0 is NSScrollView }
    }
  }

  /// The frames, in the tab view, of the page and of the AppKit controls it draws with: its
  /// fields, its lists, its scroll views. What a scroll view holds may extend past it: the scroll
  /// view is what is seen.
  private static func drawnViews(in tabView: NSTabView) -> [CGRect] {
    descendants(of: tabView)
      .filter { $0.superview === tabView || $0 is NSControl || $0 is NSScrollView }
      .filter { $0.enclosingScrollView == nil || $0 is NSScrollView }
      .filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 && $0.frame.height > 0 }
      .map { $0.convert($0.bounds, to: tabView) }
  }

  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }

  /// A window whose toolbar holds the tabs of the settings, labelled in the language given, as
  /// SwiftUI's settings window does.
  private static func toolbarWindow(language: String) -> NSWindow {
    _ = NSApplication.shared
    let tabs = NSTabViewController()
    tabs.tabStyle = .toolbar
    for tab in SettingsTab.allCases {
      let page = NSViewController()
      page.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
      let item = NSTabViewItem(viewController: page)
      item.label = Localization.string(tab.title, in: language)
      item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: nil)
      tabs.addTabViewItem(item)
    }
    let window = NSWindow(contentViewController: tabs)
    // Owned by this test, not by AppKit: a window made in code releases itself when closed.
    window.isReleasedWhenClosed = false
    window.styleMask = [.titled, .closable]
    window.toolbarStyle = .preference
    return window
  }

  /// How many tabs the toolbar shows outside its overflow menu at this width.
  private static func visibleTabs(in window: NSWindow, width: CGFloat) -> Int {
    window.setContentSize(NSSize(width: width, height: 200))
    window.layoutIfNeeded()
    return window.toolbar?.visibleItems?.count ?? 0
  }
}
