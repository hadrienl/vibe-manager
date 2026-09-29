import AppKit
import Foundation
import SwiftTerm
import Testing
import VibeApplication

@testable import VibeTerminalUI

@Suite("A click on a link in a terminal (#186)", .timeLimit(.minutes(1)))
@MainActor
struct TerminalLinkClickTests {
  @Test("A plain click waits for a double click, ⌘ opens at once, a double click never opens")
  func decisions() {
    #expect(TerminalLinkClicks.decide(clickCount: 1, command: false) == .wait)
    #expect(TerminalLinkClicks.decide(clickCount: 1, command: true) == .open)
    #expect(TerminalLinkClicks.decide(clickCount: 2, command: false) == .ignore)
    #expect(TerminalLinkClicks.decide(clickCount: 2, command: true) == .ignore)
    #expect(TerminalLinkClicks.decide(clickCount: 3, command: false) == .ignore)
  }

  @Test("A plain click opens pages and mail addresses only: another application's needs ⌘")
  func plainClickOpensPagesOnly() {
    #expect(TerminalPaneModel.opensOnClick("https://example.com"))
    #expect(TerminalPaneModel.opensOnClick("file:///tmp/report.html"))
    #expect(TerminalPaneModel.opensOnClick("mailto:a@example.com"))
    #expect(!TerminalPaneModel.opensOnClick("ssh://host"))
    #expect(!TerminalPaneModel.opensOnClick("vscode://file/tmp/a"))
    #expect(!TerminalPaneModel.opensOnClick("file:///Applications/Calculator.app"))
  }

  @Test("A plain click opens the link once the double-click interval is over")
  func plainClickOpensAfterTheInterval() async {
    let clicks = TerminalLinkClicks(sleep: { _ in })
    var opened = 0
    clicks.linkClicked(clickCount: 1, command: false) { opened += 1 }
    #expect(opened == 0)
    #expect(clicks.isWaiting)
    for _ in 0..<100 where opened == 0 { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(opened == 1)
    #expect(!clicks.isWaiting)
  }

  @Test("The next press — a double click's — cancels the click that waited")
  func pressCancels() async {
    let clicks = TerminalLinkClicks(sleep: { _ in try await Task.sleep(for: .seconds(30)) })
    var opened = 0
    clicks.linkClicked(clickCount: 1, command: false) { opened += 1 }
    clicks.pointerDown()
    #expect(!clicks.isWaiting)
    clicks.linkClicked(clickCount: 2, command: false) { opened += 1 }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(opened == 0)
  }

  @Test("⌘-click opens at once")
  func commandClickOpensAtOnce() {
    let clicks = TerminalLinkClicks(sleep: { _ in try await Task.sleep(for: .seconds(30)) })
    var opened = 0
    clicks.linkClicked(clickCount: 1, command: true) { opened += 1 }
    #expect(opened == 1)
    #expect(!clicks.isWaiting)
  }
}

/// A terminal in a window that is never shown: the tests never put a window on screen.
@MainActor
private func makeTerminal(text: String) -> (AccessibleTerminalView, NSWindow) {
  let view = AccessibleTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
  let window = NSWindow(
    contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
  window.isReleasedWhenClosed = false
  window.contentView = view
  view.feed(text: text)
  return (view, window)
}

/// Where a cell of the screen is, in the window.
@MainActor
private func point(of cell: Position, in view: AccessibleTerminalView) -> NSPoint {
  let size = view.cellSizeInPixels(source: view.getTerminal())!
  let scale = view.window?.backingScaleFactor ?? 1
  let width = CGFloat(size.width) / scale
  let height = CGFloat(size.height) / scale
  let local = NSPoint(
    x: (CGFloat(cell.col) + 0.5) * width, y: view.frame.height - (CGFloat(cell.row) + 0.5) * height)
  return view.convert(local, to: nil)
}

@MainActor
private func rightClick(at point: NSPoint, in window: NSWindow) -> NSEvent {
  NSEvent.mouseEvent(
    with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

@Suite("A terminal's links (#186)", .timeLimit(.minutes(1)))
@MainActor
struct TerminalLinkViewTests {
  @Test("A click opens a link, unless the program follows the mouse: then only ⌘-click does")
  func linkModeFollowsTheMouseMode() {
    let (view, window) = makeTerminal(text: "hello")
    defer { window.close() }
    view.syncLinkMode()
    #expect(view.linkHighlightMode == .hover)
    view.feed(text: "\u{1B}[?1000h")
    view.syncLinkMode()
    #expect(view.programFollowsMouse)
    #expect(view.linkHighlightMode == .hoverWithModifier)
    view.feed(text: "\u{1B}[?1000l")
    view.syncLinkMode()
    #expect(view.linkHighlightMode == .hover)
  }

  @Test("The link under the pointer is found in the cell it is written in")
  func findsTheLinkUnderThePointer() {
    let (view, window) = makeTerminal(text: "see https://example.com/a here")
    defer { window.close() }
    #expect(view.link(atScreen: Position(col: 8, row: 0)) == "https://example.com/a")
    #expect(view.link(atScreen: Position(col: 1, row: 0)) == nil)
    let local = view.convert(point(of: Position(col: 8, row: 0), in: view), from: nil)
    #expect(view.cell(at: local) == Position(col: 8, row: 0))
  }

  @Test("The menu of a link offers the external browser; elsewhere there is none")
  func linkMenu() throws {
    let (view, window) = makeTerminal(text: "see https://example.com/a here")
    defer { window.close() }
    var chosen: [(String, LinkGesture)] = []
    view.openLinkFromMenu = { chosen.append(($0, $1)) }
    view.hasWebView = { false }

    let menu = try #require(
      view.menu(for: rightClick(at: point(of: Position(col: 8, row: 0), in: view), in: window)))
    #expect(
      menu.items.map(\.title) == [
        LinkMenuAction.openInExternalBrowser.title, LinkMenuAction.copy.title,
      ])
    let external = try #require(menu.items.first)
    _ = external.target?.perform(external.action, with: external)
    #expect(chosen.map(\.0) == ["https://example.com/a"])
    #expect(chosen.map(\.1) == [.browser])

    view.hasWebView = { true }
    let withWebView = try #require(
      view.menu(for: rightClick(at: point(of: Position(col: 8, row: 0), in: view), in: window)))
    #expect(withWebView.items.count == 4)

    #expect(
      view.menu(for: rightClick(at: point(of: Position(col: 1, row: 0), in: view), in: window))
        == nil)
  }
}
