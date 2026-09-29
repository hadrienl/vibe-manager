import AppKit
import Foundation
import Testing
import VibeApplication

@testable import VibeConversationUI

@Suite("The menu of a link in a message (#186)")
@MainActor
struct ConversationLinkMenuTests {
  /// "see here", "here" a link, in a window that is never shown.
  private func makeProse() -> (ProseTextView, NSWindow) {
    let view = ProseTextView()
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
    let text = NSMutableAttributedString(
      string: "see here", attributes: [.font: NSFont.systemFont(ofSize: 13)])
    text.addAttribute(
      .link, value: URL(string: "https://example.com/a")!, range: NSRange(location: 4, length: 4))
    view.show(text)
    let window = NSWindow(
      contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = view
    view.layoutManager?.ensureLayout(for: view.textContainer!)
    return (view, window)
  }

  private func point(ofCharacter index: Int, in view: ProseTextView) -> NSPoint {
    let layout = view.layoutManager!
    let glyphs = layout.glyphRange(
      forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
    let rect = layout.boundingRect(forGlyphRange: glyphs, in: view.textContainer!)
    return NSPoint(
      x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
  }

  private func rightClick(at point: NSPoint, in view: NSView) -> NSEvent {
    NSEvent.mouseEvent(
      with: .rightMouseDown, location: view.convert(point, to: nil), modifierFlags: [],
      timestamp: 0, windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0,
      clickCount: 1, pressure: 1)!
  }

  @Test("The link under the pointer is the one the text holds")
  func findsTheLink() {
    let (view, window) = makeProse()
    defer { window.close() }
    #expect(view.link(at: point(ofCharacter: 5, in: view)) == URL(string: "https://example.com/a"))
    #expect(view.link(at: point(ofCharacter: 1, in: view)) == nil)
  }

  @Test("A link's actions come first, the external browser always among them")
  func menuOfALink() throws {
    let (view, window) = makeProse()
    defer { window.close() }
    var opened: [(URL, LinkGesture)] = []
    view.links = ConversationLinks(
      open: { opened.append(($0, $1)) }, hasWebView: { true })
    let menu = try #require(view.menu(for: rightClick(at: point(ofCharacter: 5, in: view), in: view)))
    let titles = menu.items.prefix(4).map(\.title)
    #expect(
      titles == [
        LinkMenuAction.openInWebView.title, LinkMenuAction.openInNewTab.title,
        LinkMenuAction.openInExternalBrowser.title, LinkMenuAction.copy.title,
      ])
    // Only ours speak of links: the text view's own Open Link and Copy Link are gone.
    #expect(menu.items.dropFirst(4).filter { $0.title.localizedCaseInsensitiveContains("link") }.isEmpty)
    let external = menu.items[2]
    _ = external.target?.perform(external.action, with: external)
    #expect(opened.map(\.1) == [.browser])

    let elsewhere = view.menu(for: rightClick(at: point(ofCharacter: 1, in: view), in: view))
    #expect(elsewhere?.items.contains { $0.title == LinkMenuAction.openInNewTab.title } != true)
  }
}
