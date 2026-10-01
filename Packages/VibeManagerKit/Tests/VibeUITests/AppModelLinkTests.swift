import AppKit
import Foundation
import Testing
import VibeApplication
import VibeBrowser
import VibeDomain

@testable import VibeUI

@Suite("A session's links, in its web view (#186)")
@MainActor
struct AppModelLinkTests {
  private func makeModel() -> (AppModel, BrowserWorkspace) {
    let browser = BrowserWorkspace()
    let model = AppModel(
      repository: StubRepository(sessions: []),
      layout: WorkspaceLayoutController(store: RecordingLayoutStore()), browser: browser)
    return (model, browser)
  }

  @Test("A click opens the web view; an address already open brings its tab forward")
  func reusesTheTabThatShowsTheAddress() {
    let (model, browser) = makeModel()
    let session = SessionID()
    let first = URL(fileURLWithPath: "/tmp/vibe-186-first.html")
    let second = URL(fileURLWithPath: "/tmp/vibe-186-second.html")
    model.openLink(first, from: session, gesture: .click(alternate: false))
    model.openLink(second, from: session, gesture: .click(alternate: false))
    model.openLink(first, from: session, gesture: .click(alternate: false))
    let tabs = browser.browser(for: session).tabs
    #expect(tabs.map(\.url) == [first, second])
    #expect(browser.browser(for: session).activeTab?.url == first)
    #expect(browser.isVisible(session))
  }

  @Test("Open in a New Tab opens one even when another shows the address")
  func newTabAlwaysOpensOne() {
    let (model, browser) = makeModel()
    let session = SessionID()
    let url = URL(fileURLWithPath: "/tmp/vibe-186-page.html")
    model.openLink(url, from: session, gesture: .webView)
    model.openLink(url, from: session, gesture: .newTab)
    #expect(browser.browser(for: session).tabs.map(\.url) == [url, url])
  }

  @Test("Open in Browser hands a page to macOS, and never a file that would run (#245)")
  func openOutsideRunsNothing() {
    let (model, _) = makeModel()
    var opened: [URL] = []
    model.openOutsideHandler = { opened.append($0) }
    let script = URL(fileURLWithPath: "/tmp/x.command")
    let page = URL(string: "https://github.com/o/r/pull/3")!

    #expect(!model.opensOutside(script))
    model.openOutside(script)
    #expect(opened.isEmpty)

    #expect(model.opensOutside(page))
    model.openOutside(page)
    #expect(opened == [page])
  }
}
