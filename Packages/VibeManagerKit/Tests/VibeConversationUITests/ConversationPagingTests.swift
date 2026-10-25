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

  /// Laid out until `condition` holds. Said where it stands before the time limit cuts it off.
  private func settled(
    _ window: NSWindow, until condition: (NSScrollView) -> Bool
  ) async throws -> NSScrollView {
    let deadline = ContinuousClock.now + Self.patience
    while ContinuousClock.now < deadline {
      window.layoutIfNeeded()
      if let scroll = scrollView(in: window.contentView), scroll.documentView != nil,
        condition(scroll)
      {
        return scroll
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let scroll = scrollView(in: window.contentView)
    Issue.record(
      "Never settled: \(scroll.map(Self.describe) ?? "no scroll view")")
    throw CancellationError()
  }

  /// Waits for the scroll view to get where `condition` says, and says where it stopped.
  private func waitUntil(
    _ step: String, _ scroll: NSScrollView, _ model: ConversationModel,
    _ condition: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + Self.patience
    while !condition() {
      guard ContinuousClock.now < deadline else {
        Issue.record(
          "Stuck at \(step): \(Self.describe(scroll)), following \(model.scroll.isFollowing)")
        throw CancellationError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Under the suite's time limit: long enough for a runner that stalls, short enough to say why.
  private static let patience: Duration = .seconds(25)

  private static func describe(_ scroll: NSScrollView) -> String {
    let bounds = scroll.contentView.bounds
    return "origin \(bounds.origin.y), visible \(bounds.height), document "
      + "\(scroll.documentView?.frame.height ?? -1), insets \(scroll.contentInsets.top)/"
      + "\(scroll.contentInsets.bottom)"
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

    model.scrollPage(.up)
    // Before the fix, nothing moves: the pager never found the messages' scroll view.
    try await waitUntil("the first page", scroll, model) {
      origin < end - 1 && !model.scroll.isFollowing
    }
    // A page is what was read, less the overlap: no line skipped under the toolbar.
    #expect(end - origin <= readable, "moved \(end - origin) for \(readable) read")
    #expect(end - origin >= readable / 2)

    // On to the start: the first message just below the toolbar, and no further.
    while origin > -top + 0.5 {
      let before = origin
      model.scrollPage(.up)
      try await waitUntil("a page up from \(before)", scroll, model) { origin < before - 0.5 }
    }
    #expect(abs(origin - -top) < 1)

    model.scrollPage(.down)
    try await waitUntil("a page down", scroll, model) { origin > -top + 1 }
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
