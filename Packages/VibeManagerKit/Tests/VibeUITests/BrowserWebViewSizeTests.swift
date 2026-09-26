import AppKit
import SwiftUI
import Testing
import VibeBrowser
import VibeDomain
import WebKit

@testable import VibeUI

@Suite("The size a page is shown at", .timeLimit(.minutes(1)))
@MainActor
struct BrowserWebViewSizeTests {
  @Test("A page moved into a view with no size yet keeps its own, then fills the view")
  func keepsItsSizeUntilTheViewHasOne() {
    let container = BrowserWebViewContainer(frame: .zero)
    let page = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 956))
    container.addSubview(page)
    #expect(page.frame.size == NSSize(width: 520, height: 956))

    container.setFrameSize(NSSize(width: 640, height: 480))
    #expect(page.frame == container.bounds)
    container.setFrameSize(NSSize(width: 300, height: 200))
    #expect(page.frame == container.bounds)
  }

  @Test("A page is never given an empty frame when its session comes back")
  func neverEmptyOnReturn() async throws {
    _ = NSApplication.shared
    let first = WorkSession(
      name: "First", status: .active, updatedAt: Date(timeIntervalSince1970: 200))
    let second = WorkSession(
      name: "Second", status: .active, updatedAt: Date(timeIntervalSince1970: 100))
    let workspace = BrowserWorkspace()
    let model = AppModel(
      repository: StubRepository(sessions: [first, second]),
      layout: WorkspaceLayoutController(store: RecordingLayoutStore()), browser: workspace)
    await model.load()
    model.select(first.id)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1800, height: 1000), styleMask: [.titled],
      backing: .buffered, defer: false)
    // Owned by this test, not by AppKit: a window made in code releases itself when closed.
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: RootView(model: model))
    defer {
      window.contentView = nil
      window.close()
    }

    let tab = workspace.open(URL(string: "about:blank")!, in: first.id, openedBy: .user)
    workspace.setVisible(true, for: first.id)
    let page = try #require(tab.webView)
    await shown(page, in: window)

    // The second session has no web view open: the panel goes, and the page is parked.
    model.select(second.id)
    while page.window === window {
      window.contentView?.layoutSubtreeIfNeeded()
      await Task.yield()
    }

    var sizes: [NSSize] = []
    page.postsFrameChangedNotifications = true
    let observer = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification, object: page, queue: nil
    ) { _ in
      MainActor.assumeIsolated { sizes.append(page.frame.size) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    model.select(first.id)
    await shown(page, in: window)
    #expect(!sizes.contains { $0.width == 0 || $0.height == 0 })
  }

  /// Waits until the page is in the panel and fills it.
  private func shown(_ page: WKWebView, in window: NSWindow) async {
    while true {
      window.contentView?.layoutSubtreeIfNeeded()
      if page.window === window, let container = page.superview as? BrowserWebViewContainer,
        !container.bounds.isEmpty, page.frame == container.bounds
      {
        return
      }
      await Task.yield()
    }
  }
}
