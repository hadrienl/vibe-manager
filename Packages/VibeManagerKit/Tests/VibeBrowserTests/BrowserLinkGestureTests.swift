import AppKit
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeBrowser

@Suite("Opening a page's link in a new tab (#186)")
@MainActor
struct BrowserLinkGestureTests {
  private func decide(
    _ modifiers: NSEvent.ModifierFlags, button: BrowserLinkGesture.Button = .primary,
    isLink: Bool = true, isAgentDriven: Bool = false
  ) -> BrowserLinkGesture.Decision {
    BrowserLinkGesture.decide(
      modifiers: modifiers, button: button, isLink: isLink, isAgentDriven: isAgentDriven)
  }

  @Test("⌘-click opens behind, ⇧⌘-click in front, the middle button behind")
  func gestures() {
    #expect(decide([.command]) == .newTab(activate: false))
    #expect(decide([.command, .shift]) == .newTab(activate: true))
    #expect(decide([], button: .middle) == .newTab(activate: false))
  }

  @Test("A plain click, what is not a link, and what an agent does stay in the tab")
  func staysInTheTab() {
    #expect(decide([]) == .sameTab)
    #expect(decide([.option]) == .sameTab)
    #expect(decide([.command], isLink: false) == .sameTab)
    #expect(decide([], button: .middle, isLink: false) == .sameTab)
    #expect(decide([.command], isAgentDriven: true) == .sameTab)
    #expect(decide([], button: .middle, isAgentDriven: true) == .sameTab)
  }

  @Test("An address of this Mac opens in a new tab from a page of this Mac only")
  func filesFromFilesOnly() {
    let file = URL(fileURLWithPath: "/tmp/a.html")
    #expect(BrowserLinkGesture.mayOpen(file, from: URL(fileURLWithPath: "/tmp/index.html")))
    #expect(!BrowserLinkGesture.mayOpen(file, from: URL(string: "https://example.com")!))
    #expect(!BrowserLinkGesture.mayOpen(file, from: nil))
    #expect(
      BrowserLinkGesture.mayOpen(
        URL(string: "https://example.com/b")!, from: URL(string: "https://example.com")!))
  }

  @Test("A new tab follows a press of the user's with the same keys, not a click made up later")
  func followsARealPress() throws {
    let view = SessionWebView(frame: .zero)
    #expect(!view.followsPress(with: [.command], now: 10))
    let press = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [.command], timestamp: 10,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    view.mouseDown(with: press)
    #expect(view.followsPress(with: [.command], now: 10.2))
    #expect(!view.followsPress(with: [.command, .shift], now: 10.2))
    #expect(!view.followsPress(with: [.command], now: 12))
  }

  @Test("A link to a file, under the pointer on a site's page, is not offered")
  func hoveredLinkFromAFileNeedsAFilePage() {
    let view = SessionWebView(frame: .zero)
    view.hoveredLink = URL(fileURLWithPath: "/tmp/a.html")
    #expect(view.openableHoveredLink == nil)
    view.hoveredLink = URL(string: "https://example.com/a")
    #expect(view.openableHoveredLink == URL(string: "https://example.com/a"))
  }

  @Test("WebKit's button number is a mask: 4 is the middle button")
  func buttonNumbers() {
    #expect(BrowserLinkGesture.Button(webKitButtonNumber: 1) == .primary)
    #expect(BrowserLinkGesture.Button(webKitButtonNumber: 2) == .other)
    #expect(BrowserLinkGesture.Button(webKitButtonNumber: 4) == .middle)
    #expect(BrowserLinkGesture.Button(webKitButtonNumber: 0) == .other)
  }
}

@Suite("The menu WebKit shows over a link (#186)")
@MainActor
struct BrowserLinkMenuTests {
  private func webKitMenu() -> NSMenu {
    let menu = NSMenu()
    for (title, identifier) in [
      ("Open Link", "WKMenuItemIdentifierOpenLink"),
      ("Open Link in New Window", "WKMenuItemIdentifierOpenLinkInNewWindow"),
      ("Download Linked File", "WKMenuItemIdentifierDownloadLinkedFile"),
      ("Copy Link", "WKMenuItemIdentifierCopyLink"),
    ] {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.identifier = NSUserInterfaceItemIdentifier(identifier)
      menu.addItem(item)
    }
    return menu
  }

  @Test("New Window becomes a new tab, and the external browser follows it")
  func rewritesALinksMenu() throws {
    let menu = webKitMenu()
    let link = URL(string: "https://example.com/a")!
    var tabs: [URL] = []
    var external: [URL] = []
    BrowserLinkMenu.rewrite(
      menu, link: link, openInNewTab: { tabs.append($0) }, openExternally: { external.append($0) })
    #expect(
      menu.items.map(\.title) == [
        "Open Link", LinkMenuAction.openInNewTab.title,
        LinkMenuAction.openInExternalBrowser.title, "Download Linked File", "Copy Link",
      ])
    for item in menu.items[1...2] {
      _ = item.target?.perform(item.action, with: item)
    }
    #expect(tabs == [link])
    #expect(external == [link])
  }

  @Test("Without a link under the pointer, or over one that is not a page, nothing changes")
  func leavesOtherMenus() {
    for link in [nil, URL(string: "mailto:a@example.com")] {
      let menu = webKitMenu()
      BrowserLinkMenu.rewrite(menu, link: link, openInNewTab: { _ in }, openExternally: { _ in })
      #expect(menu.items.count == 4)
    }
    let plain = NSMenu()
    plain.addItem(NSMenuItem(title: "Reload", action: nil, keyEquivalent: ""))
    BrowserLinkMenu.rewrite(
      plain, link: URL(string: "https://example.com")!, openInNewTab: { _ in },
      openExternally: { _ in })
    #expect(plain.items.map(\.title) == ["Reload"])
  }
}

@Suite("Where new tabs go (#186)")
@MainActor
struct BrowserTabOrderTests {
  private func url(_ name: String) -> URL { URL(string: "about:blank#\(name)")! }

  @Test("Tabs opened from a tab line up after it, in the order they were opened")
  func lineUpAfterTheirOpener() {
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let a = workspace.open(url("a"), in: session, openedBy: .user)
    let z = workspace.open(url("z"), in: session, openedBy: .user)
    workspace.browser(for: session).activate(a.id)
    for name in ["1", "2", "3"] {
      workspace.open(url(name), in: session, openedBy: .user, activate: false, from: a.id)
    }
    let browser = workspace.browser(for: session)
    #expect(browser.tabs.map(\.url) == [url("a"), url("1"), url("2"), url("3"), url("z")])
    #expect(browser.activeTab?.id == a.id)
    _ = z
  }

  @Test("Turning to another tab ends the run: the next one follows its opener again")
  func turningToATabEndsTheRun() {
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let a = workspace.open(url("a"), in: session, openedBy: .user)
    workspace.open(url("1"), in: session, openedBy: .user, activate: false, from: a.id)
    let browser = workspace.browser(for: session)
    let one = browser.tabs[1]
    browser.activate(one.id)
    browser.activate(a.id)
    workspace.open(url("2"), in: session, openedBy: .user, activate: false, from: a.id)
    #expect(browser.tabs.map(\.url) == [url("a"), url("2"), url("1")])
  }

  @Test("A tab only placed after another — a terminal's link — does not start a run")
  func placedIsNotOpened() {
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let a = workspace.open(url("a"), in: session, openedBy: .user)
    workspace.open(url("t"), in: session, openedBy: .terminalLink)
    workspace.browser(for: session).activate(a.id)
    workspace.open(url("1"), in: session, openedBy: .user, activate: false, from: a.id)
    #expect(
      workspace.browser(for: session).tabs.map(\.url) == [url("a"), url("1"), url("t")])
  }

  @Test("Opened in front, the new tab is the one shown")
  func inFront() {
    let workspace = BrowserWorkspace()
    let session = SessionID()
    let a = workspace.open(url("a"), in: session, openedBy: .user)
    let b = workspace.open(url("b"), in: session, openedBy: .user, activate: true, from: a.id)
    #expect(workspace.browser(for: session).activeTab?.id == b.id)
  }
}
