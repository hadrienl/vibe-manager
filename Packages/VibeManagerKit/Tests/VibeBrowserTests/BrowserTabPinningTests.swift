import AppKit
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeBrowser

/// Tabs the user pins stay first, after the ticket's, whatever moves them (#536).
@Suite("Pinned web tabs")
@MainActor
struct BrowserTabPinningTests {
  private let session = SessionID()

  /// A workspace with tabs `a`, `b`, `c` and `d`, in that order, none pinned.
  private func browser(in workspace: BrowserWorkspace) -> (SessionBrowser, [BrowserTabID]) {
    _ = NSApplication.shared
    for page in ["a", "b", "c", "d"] {
      workspace.open(
        URL(string: "data:text/html,<p>\(page)</p>")!, in: session, openedBy: .user,
        activate: false)
    }
    let browser = workspace.browser(for: session)
    return (browser, browser.tabs.map(\.id))
  }

  @Test("A pinned tab goes last of the pinned ones, an unpinned one first of the others")
  func pinAndUnpin() {
    let (browser, ids) = browser(in: BrowserWorkspace())

    browser.setPinned(ids[2], true)
    #expect(browser.tabs.map(\.id) == [ids[2], ids[0], ids[1], ids[3]])
    browser.setPinned(ids[3], true)
    #expect(browser.tabs.map(\.id) == [ids[2], ids[3], ids[0], ids[1]])
    #expect(browser.pinnedCount == 2)

    browser.setPinned(ids[2], false)
    #expect(browser.tabs.map(\.id) == [ids[3], ids[2], ids[0], ids[1]])
    #expect(browser.pinnedCount == 1)
  }

  @Test("A dropped tab lands before or after the row, pinned when that row's tab is")
  func dropTakesTheGroup() {
    let (browser, ids) = browser(in: BrowserWorkspace())
    browser.setPinned(ids[0], true)

    // Dropped after the pinned tab: pinned, second.
    browser.move(ids[3], nextTo: ids[0], after: true)
    #expect(browser.tabs.map(\.id) == [ids[0], ids[3], ids[1], ids[2]])
    #expect(browser.tabs.map(\.isPinned) == [true, true, false, false])

    // Dropped before the first unpinned one: no longer pinned.
    browser.move(ids[0], nextTo: ids[1], after: false)
    #expect(browser.tabs.map(\.id) == [ids[3], ids[0], ids[1], ids[2]])
    #expect(browser.tabs.map(\.isPinned) == [true, false, false, false])

    // Dropped on itself, nothing moves.
    browser.move(ids[2], nextTo: ids[2], after: true)
    #expect(browser.tabs.map(\.id) == [ids[3], ids[0], ids[1], ids[2]])
  }

  @Test("Up and down stay among the pinned tabs, or among the others")
  func movesStayInTheirGroup() {
    let (browser, ids) = browser(in: BrowserWorkspace())
    browser.setPinned(ids[0], true)
    browser.setPinned(ids[1], true)

    #expect(!browser.canMoveTab(ids[1], by: 1))
    #expect(!browser.canMoveTab(ids[2], by: -1))
    #expect(browser.canMoveTab(ids[1], by: -1))

    browser.moveTab(ids[1], by: 1)
    browser.moveTab(ids[2], by: -1)
    #expect(browser.tabs.map(\.id) == ids)

    browser.moveTab(ids[1], by: -1)
    browser.moveTab(ids[2], by: 1)
    #expect(browser.tabs.map(\.id) == [ids[1], ids[0], ids[3], ids[2]])
  }

  @Test("A tab opened from a pinned one goes after the pinned tabs, unpinned")
  func openedFromAPinnedTab() {
    let workspace = BrowserWorkspace()
    let (browser, ids) = browser(in: workspace)
    browser.setPinned(ids[0], true)
    browser.setPinned(ids[1], true)

    let first = workspace.open(
      URL(string: "data:text/html,<p>e</p>")!, in: session, openedBy: .user, activate: false,
      from: ids[0])
    let second = workspace.open(
      URL(string: "data:text/html,<p>f</p>")!, in: session, openedBy: .user, activate: false,
      from: ids[0])
    // In the order they were opened, first of the others.
    #expect(browser.tabs.map(\.id) == [ids[0], ids[1], first.id, second.id, ids[2], ids[3]])
    #expect(!first.isPinned && !second.isPinned)
  }

  @Test("Pinned tabs are kept, and come back first")
  func keptBetweenLaunches() async {
    let store = InMemoryBrowserStateStore()
    let pinned = BrowserTab(
      url: URL(string: "http://localhost:4321/docs")!, title: "Docs", openedBy: .user,
      isPinned: true)
    let other = BrowserTab(url: URL(string: "https://example.com")!, openedBy: .user)
    // Written out of order, as a hand-edited file could be.
    await store.save(SessionBrowserState(tabs: [other, pinned]), for: session)

    let workspace = BrowserWorkspace(stateStore: store)
    let browser = await workspace.restoredBrowser(for: session)
    #expect(browser.tabs.map(\.id) == [pinned.id, other.id])
    #expect(browser.persisted.tabs.map(\.isPinned) == [true, false])
  }

  @Test("A tab opened behind stays unseen until it is shown, closed, or the list is opened")
  func unseenTabs() {
    let workspace = BrowserWorkspace()
    let (browser, ids) = browser(in: workspace)
    // The four tabs opened behind.
    #expect(browser.unseenTabIDs == Set(ids))

    browser.activate(ids[0])
    workspace.close(ids[1], in: session)
    #expect(browser.unseenTabIDs == [ids[2], ids[3]])

    browser.markTabsSeen()
    #expect(browser.unseenTabIDs.isEmpty)

    // One in front is seen at once.
    workspace.open(URL(string: "data:text/html,<p>e</p>")!, in: session, openedBy: .user)
    #expect(browser.unseenTabIDs.isEmpty)
  }

  @Test("Close All closes the tabs that are not pinned, and brings a pinned one forward")
  func closeUnpinned() {
    let workspace = BrowserWorkspace()
    let (browser, ids) = browser(in: workspace)
    browser.setPinned(ids[2], true)
    browser.activate(ids[3])

    workspace.closeUnpinnedTabs(in: session)
    #expect(browser.tabs.map(\.id) == [ids[2]])
    #expect(browser.activeTab?.id == ids[2])
  }

  @Test("A tab kept before pinning existed is not pinned")
  func decodesWithoutPinning() throws {
    let json = """
      {"id":"11111111-1111-1111-1111-111111111111","url":"https://x.dev","openedBy":"user"}
      """
    let tab = try JSONDecoder().decode(BrowserTab.self, from: Data(json.utf8))
    #expect(!tab.isPinned)
  }
}
