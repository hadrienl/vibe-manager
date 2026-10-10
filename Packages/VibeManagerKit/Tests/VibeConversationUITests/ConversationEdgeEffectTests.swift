import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

/// The conversation under a toolbar, in a window never put on screen (#228). macOS 26 lays the
/// toolbar's edge effect over the whole top inset of the scroll view: that inset must stay the
/// toolbar's, however short the conversation.
@MainActor
@Suite(
  "The empty space above a short conversation is not veiled", .serialized, .timeLimit(.minutes(1)))
struct ConversationEdgeEffectTests {
  private static let height = 800.0

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
      contentRect: NSRect(x: 0, y: 0, width: 600, height: Self.height),
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

  /// Laid out, measured, and laid out again with what was measured, until `condition` holds.
  /// Cancelled by the time limit: the test fails then, rather than spinning on.
  private func settled(
    _ window: NSWindow, until condition: (NSScrollView, NSView) -> Bool
  ) async throws -> NSScrollView {
    while !Task.isCancelled {
      window.layoutIfNeeded()
      if let scroll = scrollView(in: window.contentView), let document = scroll.documentView,
        condition(scroll, document)
      {
        return scroll
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CancellationError()
  }

  /// The height of the scroll view below the toolbar, and above the composer laid over the end of
  /// the messages on macOS 26 (#359).
  private func visible(_ scroll: NSScrollView) -> Double {
    scroll.contentView.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom
  }

  /// Where the messages end in view: above the composer.
  private func visibleEnd(_ scroll: NSScrollView) -> Double {
    scroll.contentView.bounds.maxY - scroll.contentInsets.bottom
  }

  @Test("A short conversation leaves the scroll view no top inset beyond the toolbar's")
  func short() async throws {
    let (window, _) = host(messages: 1)
    defer { window.close() }
    let toolbar = window.contentView!.safeAreaInsets.top
    // Before the fix, the document stays as short as its one message.
    let scroll = try await settled(window) { scroll, document in
      document.frame.height >= visible(scroll) - 1
    }
    #expect(toolbar > 0)
    #expect(scroll.contentInsets.top == toolbar)
    let document = try #require(scroll.documentView)
    // The emptiness is the conversation's own, from the bottom: nothing to scroll.
    #expect(abs(document.frame.height - visible(scroll)) < 1)
    #expect(abs(visibleEnd(scroll) - document.frame.maxY) < 1)
  }

  @Test("A conversation taller than the view keeps that inset, and its end in view")
  func tall() async throws {
    let (window, _) = host(messages: 80)
    defer { window.close() }
    let scroll = try await settled(window) { scroll, document in
      document.frame.height > Self.height
        && abs(visibleEnd(scroll) - document.frame.maxY) < 1
    }
    let document = try #require(scroll.documentView)
    #expect(scroll.contentInsets.top == window.contentView!.safeAreaInsets.top)
    #expect(abs(visibleEnd(scroll) - document.frame.maxY) < 1)
  }
}
