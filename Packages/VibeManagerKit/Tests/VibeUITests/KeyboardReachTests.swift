import AppKit
import Foundation
import SwiftUI
import Testing
import VibeBrowser
import VibeDomain

@testable import VibeUI

/// What the keyboard alone, and VoiceOver, can do where the pointer used to be needed (#230).
@MainActor
@Suite("The keyboard reaches tabs and dividers")
struct KeyboardReachTests {
  @Test("A web tab moves one place left or right, and no further than the ends")
  func webTabMoves() {
    _ = NSApplication.shared
    let workspace = BrowserWorkspace()
    let session = SessionID()
    for page in ["a", "b", "c"] {
      _ = workspace.open(
        URL(string: "data:text/html,<p>\(page)</p>")!, in: session, openedBy: .user)
    }
    let browser = workspace.browser(for: session)
    let ids = browser.tabs.map(\.id)
    #expect(!browser.canMoveTab(ids[0], by: -1))
    #expect(browser.canMoveTab(ids[0], by: 1))
    #expect(!browser.canMoveTab(ids[2], by: 1))

    browser.moveTab(ids[0], by: 1)
    #expect(browser.tabs.map(\.id) == [ids[1], ids[0], ids[2]])
    browser.moveTab(ids[2], by: -1)
    #expect(browser.tabs.map(\.id) == [ids[1], ids[2], ids[0]])

    // At an end, nothing moves.
    browser.moveTab(ids[0], by: 1)
    browser.moveTab(ids[1], by: -1)
    #expect(browser.tabs.map(\.id) == [ids[1], ids[2], ids[0]])
  }

  @Test("The arrows across a divider size its pane as dragging that way would")
  func dividerArrows() {
    // Between columns, the divider sizes the pane on its right: left widens it.
    #expect(SplitHandle.delta(for: .leftArrow, axis: .horizontal, step: 40) == 40)
    #expect(SplitHandle.delta(for: .rightArrow, axis: .horizontal, step: 40) == -40)
    #expect(SplitHandle.delta(for: .upArrow, axis: .horizontal, step: 40) == nil)
    // Between rows, as before.
    #expect(SplitHandle.delta(for: .downArrow, axis: .vertical, step: 40) == 40)
    #expect(SplitHandle.delta(for: .upArrow, axis: .vertical, step: 40) == -40)
    #expect(
      SplitHandle.delta(for: .downArrow, axis: .vertical, step: 40, sizesPaneBelow: true) == -40)
    #expect(SplitHandle.delta(for: .leftArrow, axis: .vertical, step: 40) == nil)
  }

  @Test("No VoiceOver hint asks for a double-click, which VoiceOver cannot make")
  func noDoubleClickHint() throws {
    let catalog = try Data(contentsOf: Self.sourceCatalog)
    let keys = try #require(
      (JSONSerialization.jsonObject(with: catalog) as? [String: Any])?["strings"]
        as? [String: Any]
    ).keys
    let asking = keys.filter {
      $0.localizedCaseInsensitiveContains("double-click")
        && !$0.localizedCaseInsensitiveContains("Return")
    }
    #expect(asking.isEmpty, "\(asking)")
  }

  /// VibeUI's catalog, read from the sources: the built bundle holds compiled strings.
  private static var sourceCatalog: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/VibeUI/Localizable.xcstrings")
  }
}
