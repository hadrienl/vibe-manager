import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

/// Page Up and Page Down from the composer scroll the messages themselves (#227), in a window
/// never put on screen, under a toolbar like the application's.
@MainActor
@Suite(
  "Paging through the conversation from the keyboard (#227)", .serialized, .timeLimit(.minutes(1)))
struct ConversationPagingTests {
  private func host(messages: Int) -> (NSWindow, ConversationModel) {
    let model = ConversationModel(sessionID: SessionID())
    model.write = { _ in }
    model.processRunning = { true }
    model.apply(
      ConversationSnapshot(
        entries: (0..<messages).map {
          ConversationEntry(id: "m\($0)", content: .agentText("Message \($0)"))
        }, availability: .available))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
      styleMask: [.titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.toolbar = NSToolbar()
    window.contentView = NSHostingView(
      rootView: ConversationView(
        model: model, theme: .systemDark, appearance: ConversationAppearance()))
    return (window, model)
  }

  private func scrollView(in view: NSView?) -> NSScrollView? {
    guard let view else { return nil }
    return view as? NSScrollView ?? view.subviews.lazy.compactMap(scrollView(in:)).first
  }

  /// Laid out until `condition` holds; cancelled by the time limit rather than spinning on.
  private func settled(
    _ window: NSWindow, until condition: (NSScrollView) -> Bool
  ) async throws -> NSScrollView {
    while !Task.isCancelled {
      window.layoutIfNeeded()
      if let scroll = scrollView(in: window.contentView), scroll.documentView != nil,
        condition(scroll)
      {
        return scroll
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CancellationError()
  }

  /// Waits for the scroll view to get where `condition` says; cancelled by the time limit.
  private func waitUntil(_ condition: () -> Bool) async throws {
    while !condition() {
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Waits for the origin to stop moving: the same on several readings in a row.
  private func settledOrigin(_ origin: () -> Double) async throws {
    var last = origin()
    var still = 0
    while still < 5 {
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(20))
      let now = origin()
      still = abs(now - last) < 0.5 ? still + 1 : 0
      last = now
    }
  }

  @Test("Page Up scrolls the messages, page after page, up to the first one below the toolbar")
  func pagesUp() async throws {
    let (window, model) = host(messages: 120)
    defer { window.close() }
    // At the end of a long conversation, as it opens.
    let scroll = try await settled(window) { scroll in
      let document = scroll.documentView!.frame.height
      return document > 2000 && scroll.contentView.bounds.maxY >= document - 1
    }
    let top = scroll.contentInsets.top
    #expect(top > 0)
    let readable = scroll.contentView.bounds.height - top - scroll.contentInsets.bottom
    var origin: Double { scroll.contentView.bounds.origin.y }
    let end = origin
    let endHeight = scroll.documentView!.frame.height

    model.scrollPage(.up)
    // Before the fix, nothing moves: the pager never found the messages' scroll view. A scroll
    // can be eased on some systems: what is waited for is where it lands, at least half a page up.
    try await waitUntil { origin <= end - readable / 2 && !model.scroll.isFollowing }
    try await settledOrigin { origin }
    // A page is what was read, less the overlap: no line skipped under the toolbar.
    #expect(end - origin <= readable, "moved \(end - origin) for \(readable) read; document \(endHeight) then \(scroll.documentView!.frame.height); insets \(scroll.contentInsets.top) \(scroll.contentInsets.bottom); page scroll \(scroll.verticalPageScroll)")

    // On to the start: the first message just below the toolbar, and no further.
    while origin > -top + 0.5 {
      let before = origin
      model.scrollPage(.up)
      try await waitUntil { origin < before - 0.5 }
      try await settledOrigin { origin }
    }
    #expect(abs(origin - -top) < 1)

    model.scrollPage(.down)
    try await waitUntil { origin > -top + 1 }
  }

  @Test("A draft taller than its field keeps Page Up, Page Down and End to scroll itself")
  func scrollingDraft() {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    scroll.documentView = text
    #expect(!PromptComposer.draftScrolls(in: text))
    text.frame.size.height = 300
    #expect(PromptComposer.draftScrolls(in: text))
    #expect(!PromptComposer.draftScrolls(in: nil))
  }

  @Test("Read aloud, a message keeps the numbers of its steps and the state of its tasks")
  func plainList() {
    #expect(
      MarkdownDocument.plainText(from: "Steps:\n\n3. first\n4. *second*\n\n- [x] done\n- [ ] todo")
        == "Steps:\n3. first\n4. second\n☑ done\n☐ todo")
  }
}
