import AppKit
import Foundation
import Testing
import VibeApplication

@testable import VibeConversationUI

@Suite("The menu of a link in a message (#186)")
@MainActor
struct ConversationLinkMenuTests {
  /// "see here", "here" a link, in a window that is never shown.
  private func makeProse() -> (SegmentTextView, NSWindow) {
    let view = SegmentTextView()
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

  private func point(ofCharacter index: Int, in view: SegmentTextView) -> NSPoint {
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
    let menu = try #require(
      view.menu(for: rightClick(at: point(ofCharacter: 5, in: view), in: view)))
    let titles = menu.items.prefix(4).map(\.title)
    #expect(
      titles == [
        LinkMenuAction.openInWebView.title, LinkMenuAction.openInNewTab.title,
        LinkMenuAction.openInExternalBrowser.title, LinkMenuAction.copy.title,
      ])
    // Only ours speak of links: the text view's own Open Link and Copy Link are gone.
    #expect(
      menu.items.dropFirst(4).filter { $0.title.localizedCaseInsensitiveContains("link") }.isEmpty)
    let external = menu.items[2]
    _ = external.target?.perform(external.action, with: external)
    #expect(opened.map(\.1) == [.browser])

    let elsewhere = view.menu(for: rightClick(at: point(ofCharacter: 1, in: view), in: view))
    #expect(elsewhere?.items.contains { $0.title == LinkMenuAction.openInNewTab.title } != true)
  }
}

@Suite("Bare addresses in a message are links (#186)")
struct BareAddressLinkTests {
  private func runs(_ text: String) -> [InlineRun] {
    guard case .paragraph(let runs) = MarkdownDocument.blocks(from: text).first else { return [] }
    return runs
  }

  @Test("An address written as is becomes a link, the text around it stays text")
  func bareAddress() {
    let runs = runs("Ouvert ici : https://github.com/hadrienl/vibe-manager/issues/189. Voilà")
    #expect(
      runs.map(\.text).joined()
        == "Ouvert ici : https://github.com/hadrienl/vibe-manager/issues/189. Voilà")
    let links = runs.compactMap(\.link)
    #expect(links == [URL(string: "https://github.com/hadrienl/vibe-manager/issues/189")!])
    #expect(
      runs.first { $0.link != nil }?.text == "https://github.com/hadrienl/vibe-manager/issues/189")
  }

  @Test("Two addresses, bold kept, and a paragraph of its own")
  func severalAddresses() {
    let runs = runs("**voir http://a.example/x et https://b.example/y**")
    #expect(
      runs.compactMap(\.link).map(\.absoluteString) == [
        "http://a.example/x", "https://b.example/y",
      ])
    #expect(runs.allSatisfy { $0.isBold })
    #expect(self.runs("https://github.com/o/r/pull/3").compactMap(\.link).count == 1)
  }

  @Test("What has no scheme, another scheme, or is code stays text")
  func notAddresses() {
    #expect(runs("example.com and github.com/o/r").compactMap(\.link).isEmpty)
    #expect(runs("ftp://files.example/a and javascript://x").compactMap(\.link).isEmpty)
    #expect(runs("`https://example.com/a`").compactMap(\.link).isEmpty)
  }

  @Test("A written link keeps its own address")
  func writtenLink() {
    let runs = runs("[the PR](https://github.com/o/r/pull/3)")
    #expect(runs.compactMap(\.link) == [URL(string: "https://github.com/o/r/pull/3")!])
    #expect(runs.map(\.text) == ["the PR"])
  }
}
