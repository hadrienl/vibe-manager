import AppKit
import SwiftUI
import Testing
import VibeBrowser
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

    #expect(Self.visibleTabs(in: window, width: SettingsView.formWidth) == 10)
    // The measure can see an overflow: at the width of #129, the last tabs are out.
    #expect(Self.visibleTabs(in: window, width: 500) < 10)
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
