import AppKit
import SwiftUI
import Testing

@testable import VibeUI

@MainActor
@Suite("A prompt area that grows with its text", .timeLimit(.minutes(1)))
struct PromptTextEditorTests {
  /// Hosts the editor in a window that is never shown, and returns its height once laid out.
  private func height(of text: String, width: CGFloat = 400, minimumLines: Int = 3) async throws
    -> CGFloat
  {
    let host = NSHostingView(
      rootView: Host(text: text, minimumLines: minimumLines).frame(width: width))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
      styleMask: [.borderless], backing: .buffered, defer: false)
    // Owned by this test, not by AppKit: a window made in code releases itself when closed.
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    // As on a Mac set to always show scroll bars, which the CI runner is: the style the system
    // hands every scroll view when that preference changes.
    host.layoutSubtreeIfNeeded()
    Self.scrollView(in: host)?.scrollerStyle = .legacy
    // The editor publishes its height after the layout pass that measured it, and SwiftUI applies
    // it on a later one — later still on a busy runner. It is read once the view is as tall as its
    // text view asks, with no deadline of its own: the suite's time limit stops one that never is.
    while true {
      host.layoutSubtreeIfNeeded()
      if let textView = Self.textView(in: host),
        let wanted = PromptTextStyle.height(
          of: textView, minimumLines: minimumLines,
          maximumLines: PromptTextEditor.defaultMaximumLines),
        host.fittingSize.height == wanted
      {
        return wanted
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private static func scrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView { return scrollView }
    return view.subviews.lazy.compactMap(scrollView(in:)).first
  }

  private static func textView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    return view.subviews.lazy.compactMap(textView(in:)).first
  }

  private struct Host: View {
    @State var text: String
    let minimumLines: Int

    var body: some View {
      PromptTextEditor(text: $text, minimumLines: minimumLines, accessibilityLabel: "Prompt")
    }
  }

  private var line: CGFloat { PromptTextStyle.lineHeight }

  @Test("Empty, it keeps its minimum")
  func emptyKeepsMinimum() async throws {
    let height = try await height(of: "")
    #expect(abs(height - PromptTextStyle.height(forLines: 3)) <= 1)
  }

  @Test("It grows line by line, then stops at ten lines")
  func growsThenStops() async throws {
    let five = try await height(of: (1...5).map { "line \($0)" }.joined(separator: "\n"))
    let thirty = try await height(of: (1...30).map { "line \($0)" }.joined(separator: "\n"))
    #expect(abs(five - PromptTextStyle.height(forLines: 5)) <= 2)
    #expect(abs(thirty - PromptTextStyle.height(forLines: 10)) <= 2)
  }

  @Test("A line that wraps counts as the lines it takes on screen")
  func wrappedLinesCount() async throws {
    let long = String(repeating: "word ", count: 60)
    let wide = try await height(of: long, width: 900, minimumLines: 1)
    let narrow = try await height(of: long, width: 250, minimumLines: 1)
    #expect(narrow > wide + line)
  }
}
